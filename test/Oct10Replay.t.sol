// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DeskTest } from "./base/DeskTest.sol";
import { DeskParams } from "../src/libs/DeskParams.sol";
import { Side } from "../src/libs/Regime.sol";

/// @notice The screen. Two makers from one wallet, the same inventory, the same tape, an arb taker
///         and a flow taker every minute, both inventories marked at spot. Writes
///         results/oct10_replay.csv; the last row is the two numbers.
///
///         forge test --match-contract Oct10Replay -vv
///
/// @dev The columns are frozen: `HEADER` is the schema, `results/oct10_replay.schema.md` gives the
///      units, and `app/src/types.ts` mirrors it field for field. Anything reading the CSV can be
///      built against it now.
///
///      What is real in the file today: the book columns come from the tape, and `deskBid`,
///      `deskAsk`, `lean` and `dislocationBps` are the shipped `CoreQuote` answering under it —
///      the contract, not a model of it. What is not: the two takers. `arbTaker` and `flowTaker`
///      are placeholders until orders can be shipped through the official router, so every
///      inventory, PnL, absorbed, arb and markout number in the committed CSV is synthetic. The
///      `.source` file next to it names the tape it came from, and `PLACEHOLDER_TAKERS` makes this
///      suite fail the moment the real tape lands with the placeholder still in place.
contract Oct10ReplayTest is DeskTest {
    /// @dev One minute of tape/oct10_btc_1m.json. Fields alphabetical: vm.parseJson decodes structs
    ///      in that order.
    struct Tick {
        uint64 ask;
        uint64 bid;
        uint256 forcedBuyNtl;
        uint256 forcedSellNtl;
        uint64 mark;
        uint64 oracle;
        uint256 spot;
        uint256 t;
        uint256 takerNtl;
    }

    /// @dev What one minute leaves behind for both makers. Field order is the CSV column order and
    ///      is frozen; see HEADER.
    struct Row {
        uint256 t;
        uint256 spot;
        uint256 bid;
        uint256 ask;
        uint256 mark;
        uint256 oracle;
        uint256 deskBid;
        uint256 deskAsk;
        uint8 lean;
        int256 dislocationBps;
        uint256 mapBelowNtl;
        uint256 mapAboveNtl;
        uint256 forcedSellNtl;
        uint256 forcedBuyNtl;
        uint256 baseDesk;
        uint256 quoteDesk;
        uint256 baseControl;
        uint256 quoteControl;
        int256 pnlDeskBps;
        int256 pnlControlBps;
        uint256 absorbedDeskNtl;
        uint256 absorbedControlNtl;
        uint256 arbDeskNtl;
        uint256 arbControlNtl;
        int256 markoutDesk5mBps;
        int256 markoutDesk15mBps;
        int256 markoutDesk60mBps;
        int256 markoutControl5mBps;
        int256 markoutControl15mBps;
        int256 markoutControl60mBps;
    }

    string internal constant HEADER = "t,spot,bid,ask,mark,oracle,deskBid,deskAsk,lean,dislocationBps,"
        "mapBelowNtl,mapAboveNtl,forcedSellNtl,forcedBuyNtl,baseDesk,quoteDesk,baseControl,quoteControl,"
        "pnlDeskBps,pnlControlBps,absorbedDeskNtl,absorbedControlNtl,arbDeskNtl,arbControlNtl,"
        "markoutDesk5mBps,markoutDesk15mBps,markoutDesk60mBps,"
        "markoutControl5mBps,markoutControl15mBps,markoutControl60mBps";

    string internal constant TAPE = "tape/oct10_btc_1m.json";
    string internal constant STUB_TAPE = "tape/oct10_btc_1m.stub.json";
    string internal constant OUT = "results/oct10_replay.csv";
    string internal constant SOURCE = "results/oct10_replay.source";

    /// @dev Flip to false in the same commit that makes the takers real.
    bool internal constant PLACEHOLDER_TAKERS = true;

    /// @dev The markout horizons, in minutes. keeper/coldcascade/tape.py mirrors them in
    ///      MARKOUT_HORIZONS_MINUTES and cuts the tape's tail from the longest.
    uint256 internal constant MARKOUT_5M = 5;
    uint256 internal constant MARKOUT_15M = 15;
    uint256 internal constant MARKOUT_60M = 60;
    uint256 internal constant LONGEST_MARKOUT = MARKOUT_60M;

    uint16 internal constant ARB_EDGE_BPS = 10;       // todo: set from the dry run
    uint16 internal constant ARB_SHARE_BPS = 500;     // share of the minute's aggressive flow the arb is
    uint16 internal constant FLOW_CAPTURE_BPS = 10;   // share of the minute's forced notional routed here

    uint256 internal constant START_BASE = 40e8;           // 40 UBTC, both makers
    uint256 internal constant START_QUOTE = 5_000_000e6;   // 5 000 000 USDT0, both makers

    uint256 internal baseDesk;
    uint256 internal quoteDesk;
    uint256 internal baseControl;
    uint256 internal quoteControl;
    uint256 internal startValue;

    /// @dev Raw price the placeholder flow filled at this minute, per maker. Zero means no fill.
    uint256[] internal deskFillPx;
    uint256[] internal controlFillPx;

    DeskParams internal params;

    function test_replay_writesResults() public {
        (Tick[] memory tape, bool isRealTape) = loadTape();
        assertGt(tape.length, 0, "the tape is empty");
        assertFalse(isRealTape && PLACEHOLDER_TAKERS, "real tape present: the takers have to be real too");

        Row[] memory rows = run(tape);
        writeResults(rows, tape, isRealTape);

        string memory written = vm.readFile(OUT);
        assertEq(_firstLine(written), HEADER, "the committed CSV must carry the frozen header");
        assertEq(_lineCount(written), tape.length + 1, "one header, one row per minute");

        // The regimes the tape is built to cross. If a change to Regime silences one of them, the
        // screen is drawing a straight line and this says so before the video does.
        assertEq(rows[0].lean, uint8(Side.None), "the tape opens quiet");
        assertTrue(_sawLean(rows, Side.Bid), "no minute leaned the bid");
        assertTrue(_sawLean(rows, Side.Ask), "no minute leaned the ask");
    }

    /// @dev Hashed in memory rather than through the file, because forge runs the cases in a suite
    ///      in parallel and they would otherwise be writing over each other's CSV.
    function test_replay_isDeterministic() public {
        (Tick[] memory tape,) = loadTape();
        bytes32 first = digest(run(tape));
        setUp();
        assertEq(digest(run(tape)), first, "same tape, same rows");
    }

    function digest(Row[] memory rows) internal pure returns (bytes32 h) {
        for (uint256 i = 0; i < rows.length; ++i) {
            h = keccak256(abi.encodePacked(h, csv(rows[i])));
        }
    }

    /// @dev The tape has to outlive its own last fill by the longest markout horizon, or
    ///      `markoutDesk60mBps` is structurally zero for every fill the desk made and the screen
    ///      shows only the half of the trade that loses — the minutes where the desk is holding
    ///      what it just caught and is still underwater on it. `select_window` in
    ///      keeper/coldcascade/tape.py cuts the window to guarantee this; here is the assertion.
    ///
    ///      The fix when this fails is a longer tape, never a shorter horizon.
    function test_tape_coversTheLongestMarkout() public {
        (Tick[] memory tape,) = loadTape();
        Row[] memory rows = run(tape);

        bool anyFill;
        uint256 lastFill;
        for (uint256 i = 0; i < rows.length; ++i) {
            if (deskFillPx[i] != 0 || controlFillPx[i] != 0) {
                lastFill = i;
                anyFill = true;
            }
        }
        assertTrue(anyFill, "the tape produced no fills at all");
        assertLt(
            lastFill + LONGEST_MARKOUT,
            tape.length,
            "the tape stops inside the last fill's longest markout: extend the tape, not the horizon"
        );

        bool anyMarkout60;
        for (uint256 i = 0; i < rows.length; ++i) {
            if (rows[i].markoutDesk60mBps != 0) anyMarkout60 = true;
        }
        assertTrue(anyMarkout60, "no fill in the file carries a 60 minute markout: the column is dead");
    }

    /// @dev A markout needs a later spot, so a minute the tape does not reach past is written as
    ///      zero. After test_tape_coversTheLongestMarkout that can only be the tail itself.
    function test_replay_fillsCarryMarkouts() public {
        (Tick[] memory tape,) = loadTape();
        Row[] memory rows = run(tape);

        bool anyFill;
        for (uint256 i = 0; i < rows.length; ++i) {
            if (deskFillPx[i] == 0) continue;
            anyFill = true;
            bool hasLaterSpot = i + MARKOUT_5M < tape.length;
            assertEq(
                rows[i].markoutDesk5mBps != 0 || !hasLaterSpot,
                true,
                "a fill with five minutes of tape after it must have a 5 m markout"
            );
        }
        assertTrue(anyFill, "the tape produced no fills at all");
    }

    // ---- the loop ----

    function run(Tick[] memory tape) internal returns (Row[] memory rows) {
        params = btcParams();
        params.mapOracle = address(mapOracle);

        baseDesk = START_BASE;
        quoteDesk = START_QUOTE;
        baseControl = START_BASE;
        quoteControl = START_QUOTE;
        startValue = valueAtSpot(START_BASE, START_QUOTE, tape[0].spot);

        deskFillPx = new uint256[](tape.length);
        controlFillPx = new uint256[](tape.length);

        rows = new Row[](tape.length);
        for (uint256 i = 0; i < tape.length; ++i) {
            Tick memory tick = tape[i];
            _minute = i;
            vm.warp(tick.t);
            setBook(tick.bid, tick.ask, tick.mark, tick.oracle);
            mapOracle.update(BTC, uint128(tick.forcedSellNtl), uint128(tick.forcedBuyNtl));

            arbTaker(tick);
            uint256 absorbed = flowTaker(tick);
            rows[i] = markToSpot(tick, absorbed);
        }
        markouts(rows, tape);
    }

    function loadTape() internal view returns (Tick[] memory tape, bool isRealTape) {
        isRealTape = vm.exists(TAPE);
        string memory path = isRealTape ? TAPE : STUB_TAPE;
        tape = abi.decode(vm.parseJson(vm.readFile(path)), (Tick[]));
    }

    /// @notice If a maker's marginal price is off spot by more than the edge, trade it back.
    ///         For the desk this mostly finds nothing to do, which is the point.
    /// @dev Placeholder. The real one prices both makers' marginal rate through the official
    ///      router and trades the closed-form size that brings it back to spot. This one bleeds
    ///      the control a fixed share of the minute's aggressive flow and leaves the desk alone,
    ///      which is the shape the real thing is expected to have and none of its magnitude.
    function arbTaker(Tick memory tick) internal returns (uint256 fromDesk, uint256 fromControl) {
        if (!PLACEHOLDER_TAKERS) revert("todo: the real arb taker");
        fromControl = tick.takerNtl * ARB_SHARE_BPS / 10_000 * ARB_EDGE_BPS / 10_000;
        quoteControl = quoteControl > fromControl * 1e6 ? quoteControl - fromControl * 1e6 : 0;
        lastArbDesk = fromDesk;
        lastArbControl = fromControl;
    }

    /// @notice Route the minute's forced flow to whoever quotes best, best price first.
    /// @dev Placeholder. The real one quotes both makers through the router and fills against the
    ///      better one. This one hands the desk a share of the forced notional while it is leaning
    ///      and the control a quarter of that always, at each maker's own quoted price.
    function flowTaker(Tick memory tick) internal returns (uint256 absorbedNtl) {
        if (!PLACEHOLDER_TAKERS) revert("todo: the real flow taker");

        (uint256 deskBidPx, uint256 deskAskPx, Side lean) = coreQuote.bounds(params);

        if (tick.forcedSellNtl != 0) {
            uint256 share = lean == Side.Bid ? FLOW_CAPTURE_BPS : FLOW_CAPTURE_BPS / 4;
            absorbedNtl = tick.forcedSellNtl * share / 10_000;
            _buyBase(absorbedNtl, deskBidPx, true);
            _buyBase(tick.forcedSellNtl * (FLOW_CAPTURE_BPS / 4) / 10_000, uint256(tick.bid), false);
        } else if (tick.forcedBuyNtl != 0) {
            uint256 share = lean == Side.Ask ? FLOW_CAPTURE_BPS : FLOW_CAPTURE_BPS / 4;
            absorbedNtl = tick.forcedBuyNtl * share / 10_000;
            _sellBase(absorbedNtl, deskAskPx, true);
            _sellBase(tick.forcedBuyNtl * (FLOW_CAPTURE_BPS / 4) / 10_000, uint256(tick.ask), false);
        }
        lastAbsorbedControl = tick.forcedSellNtl != 0 || tick.forcedBuyNtl != 0
            ? (tick.forcedSellNtl + tick.forcedBuyNtl) * (FLOW_CAPTURE_BPS / 4) / 10_000
            : 0;
    }

    function markToSpot(Tick memory tick, uint256 absorbedNtl) internal view returns (Row memory row) {
        (uint256 deskBidPx, uint256 deskAskPx, Side lean) = coreQuote.bounds(params);

        row.t = tick.t;
        row.spot = tick.spot;
        row.bid = tick.bid;
        row.ask = tick.ask;
        row.mark = tick.mark;
        row.oracle = tick.oracle;
        row.deskBid = deskBidPx;
        row.deskAsk = deskAskPx;
        row.lean = uint8(lean);
        row.dislocationBps = coreQuote.regime(params).dislocationBps;
        row.mapBelowNtl = tick.forcedSellNtl;
        row.mapAboveNtl = tick.forcedBuyNtl;
        row.forcedSellNtl = tick.forcedSellNtl;
        row.forcedBuyNtl = tick.forcedBuyNtl;
        row.baseDesk = baseDesk;
        row.quoteDesk = quoteDesk;
        row.baseControl = baseControl;
        row.quoteControl = quoteControl;
        row.pnlDeskBps = pnlBps(baseDesk, quoteDesk, tick.spot);
        row.pnlControlBps = pnlBps(baseControl, quoteControl, tick.spot);
        row.absorbedDeskNtl = absorbedNtl;
        row.absorbedControlNtl = lastAbsorbedControl;
        row.arbDeskNtl = lastArbDesk;
        row.arbControlNtl = lastArbControl;
        // The markout columns are a second pass: they need minutes this one has not seen yet.
    }

    /// @dev A markout is the later spot against the price the minute filled at, signed so that a
    ///      positive number is the maker being right. Minutes with no fill, and minutes the tape
    ///      does not reach past, are zero.
    function markouts(Row[] memory rows, Tick[] memory tape) internal view {
        for (uint256 i = 0; i < rows.length; ++i) {
            rows[i].markoutDesk5mBps = markoutAt(deskFillPx[i], tape, i, MARKOUT_5M, true);
            rows[i].markoutDesk15mBps = markoutAt(deskFillPx[i], tape, i, MARKOUT_15M, true);
            rows[i].markoutDesk60mBps = markoutAt(deskFillPx[i], tape, i, MARKOUT_60M, true);
            rows[i].markoutControl5mBps = markoutAt(controlFillPx[i], tape, i, MARKOUT_5M, true);
            rows[i].markoutControl15mBps = markoutAt(controlFillPx[i], tape, i, MARKOUT_15M, true);
            rows[i].markoutControl60mBps = markoutAt(controlFillPx[i], tape, i, MARKOUT_60M, true);
        }
    }

    function markoutAt(uint256 fillPx, Tick[] memory tape, uint256 i, uint256 horizon, bool bought)
        internal
        pure
        returns (int256)
    {
        if (fillPx == 0 || i + horizon >= tape.length) return 0;
        int256 later = int256(tape[i + horizon].spot);
        int256 filled = int256(fillPx);
        int256 move = (later - filled) * 10_000 / filled;
        return bought ? move : -move;
    }

    // ---- writing ----

    function writeResults(Row[] memory rows, Tick[] memory tape, bool isRealTape) internal {
        vm.writeFile(OUT, string.concat(HEADER, "\n"));
        for (uint256 i = 0; i < rows.length; ++i) {
            writeRow(rows[i]);
        }

        string memory path = isRealTape ? TAPE : STUB_TAPE;
        vm.writeFile(
            SOURCE,
            string.concat(
                "tape: ", path, "\n",
                "keccak256: ", vm.toString(keccak256(bytes(vm.readFile(path)))), "\n",
                "ticks: ", vm.toString(tape.length), "\n",
                "takers: ", PLACEHOLDER_TAKERS ? "placeholder" : "router", "\n"
            )
        );
    }

    function writeRow(Row memory row) internal {
        vm.writeLine(OUT, csv(row));
    }

    function csv(Row memory r) internal pure returns (string memory) {
        return string.concat(
            _u(r.t), ",", _u(r.spot), ",", _u(r.bid), ",", _u(r.ask), ",", _u(r.mark), ",", _u(r.oracle),
            ",", _u(r.deskBid), ",", _u(r.deskAsk), ",", _u(r.lean), ",", _i(r.dislocationBps),
            ",", _u(r.mapBelowNtl), ",", _u(r.mapAboveNtl), ",", _u(r.forcedSellNtl), ",", _u(r.forcedBuyNtl),
            ",", _u(r.baseDesk), ",", _u(r.quoteDesk), ",", _u(r.baseControl), ",", _u(r.quoteControl),
            ",", _i(r.pnlDeskBps), ",", _i(r.pnlControlBps),
            ",", _u(r.absorbedDeskNtl), ",", _u(r.absorbedControlNtl), ",", _u(r.arbDeskNtl), ",", _u(r.arbControlNtl),
            ",", _i(r.markoutDesk5mBps), ",", _i(r.markoutDesk15mBps), ",", _i(r.markoutDesk60mBps),
            ",", _i(r.markoutControl5mBps), ",", _i(r.markoutControl15mBps), ",", _i(r.markoutControl60mBps)
        );
    }

    // ---- inventory ----

    uint256 internal lastAbsorbedControl;
    uint256 internal lastArbDesk;
    uint256 internal lastArbControl;

    /// @dev One maker's side of the minute's flow, at its own quoted price. Notionals are whole
    ///      dollars, so a quote leg of `notionalUsd` is `notionalUsd * 1e6` USDT0 units. A maker
    ///      that cannot afford the whole clip takes what it can; nothing here is allowed to make
    ///      inventory out of nothing, which is the one way a placeholder could flatter the screen.
    function _buyBase(uint256 notionalUsd, uint256 rawPx, bool isDesk) private {
        if (notionalUsd == 0 || rawPx == 0) return;
        uint256 quoteUnits = notionalUsd * 1e6;
        uint256 held = isDesk ? quoteDesk : quoteControl;
        if (quoteUnits > held) quoteUnits = held;
        if (quoteUnits == 0) return;

        uint256 baseUnits = quoteUnits * params.pxDen / (rawPx * params.pxNum);
        if (isDesk) {
            quoteDesk -= quoteUnits;
            baseDesk += baseUnits;
            deskFillPx[_minute] = rawPx;
        } else {
            quoteControl -= quoteUnits;
            baseControl += baseUnits;
            controlFillPx[_minute] = rawPx;
        }
    }

    function _sellBase(uint256 notionalUsd, uint256 rawPx, bool isDesk) private {
        if (notionalUsd == 0 || rawPx == 0) return;
        uint256 baseUnits = notionalUsd * 1e6 * params.pxDen / (rawPx * params.pxNum);
        uint256 held = isDesk ? baseDesk : baseControl;
        if (baseUnits > held) baseUnits = held;
        if (baseUnits == 0) return;

        uint256 quoteUnits = baseUnits * rawPx * params.pxNum / params.pxDen;
        if (isDesk) {
            baseDesk -= baseUnits;
            quoteDesk += quoteUnits;
            deskFillPx[_minute] = rawPx;
        } else {
            baseControl -= baseUnits;
            quoteControl += quoteUnits;
            controlFillPx[_minute] = rawPx;
        }
    }

    uint256 internal _minute;

    function valueAtSpot(uint256 base, uint256 quote_, uint256 spot) internal view returns (uint256) {
        return base * spot * params.pxNum / params.pxDen + quote_;
    }

    function pnlBps(uint256 base, uint256 quote_, uint256 spot) internal view returns (int256) {
        int256 now_ = int256(valueAtSpot(base, quote_, spot));
        int256 start = int256(startValue);
        return (now_ - start) * 10_000 / start;
    }

    // ---- string and file helpers ----

    function _u(uint256 v) private pure returns (string memory) {
        return vm.toString(v);
    }

    function _i(int256 v) private pure returns (string memory) {
        return vm.toString(v);
    }

    function _firstLine(string memory file) private pure returns (string memory) {
        bytes memory b = bytes(file);
        uint256 n;
        while (n < b.length && b[n] != "\n") ++n;
        bytes memory head = new bytes(n);
        for (uint256 i = 0; i < n; ++i) {
            head[i] = b[i];
        }
        return string(head);
    }

    function _lineCount(string memory file) private pure returns (uint256 lines) {
        bytes memory b = bytes(file);
        for (uint256 i = 0; i < b.length; ++i) {
            if (b[i] == "\n") ++lines;
        }
    }

    function _sawLean(Row[] memory rows, Side side) private pure returns (bool) {
        for (uint256 i = 0; i < rows.length; ++i) {
            if (rows[i].lean == uint8(side)) return true;
        }
        return false;
    }
}
