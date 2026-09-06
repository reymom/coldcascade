// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { BlindTakers } from "./base/BlindTakers.sol";
import { DeskParams } from "../src/libs/DeskParams.sol";
import { Side } from "../src/libs/Regime.sol";

/// @notice The screen. Two makers shipped from one wallet with the same inventory, the same tape,
///         and two takers that cannot tell them apart: an arbitrageur and a forced seller, every
///         minute. Both inventories marked at spot. Writes results/oct10_replay.csv; the last row
///         is the two numbers.
///
///         forge test --match-contract Oct10Replay -vv
///
/// @dev The columns are frozen: `HEADER` is the schema, `results/oct10_replay.schema.md` gives the
///      units, and `app/src/types.ts` mirrors it field for field.
///
///      **The takers are real.** Both quote and settle through the official router, against
///      strategies shipped into Aqua, and neither has any way to learn which maker is which — see
///      `BlindTakers` for what that costs and `test_takers_areBlind` for the test that enforces it.
///      What is still modelled is the tape: `keeper/coldcascade/tape.py` keeps Coinbase spot and
///      `takerNtl` real and derives `mark`, `bid`, `ask` and the forced columns from the price
///      path. The desk's whole advantage in a lean is the distance from L1's bid to L1's ask, so
///      the overlay's `SPREAD_GAIN` is a dial on the headline number until a real tape lands.
///      `results/oct10_replay.source` names the tape and its hash.
contract Oct10ReplayTest is BlindTakers {
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
        uint256 baseHard;
        uint256 quoteHard;
        int256 pnlHardBps;
        uint256 absorbedHardNtl;
        uint256 arbHardNtl;
        int256 markoutHard5mBps;
        int256 markoutHard15mBps;
        int256 markoutHard60mBps;
        uint256 absorbedTouchNtl;
        int256 markoutTouch5mBps;
        int256 markoutTouch15mBps;
        int256 markoutTouch60mBps;
        uint256 lvrDeskNtl;
        uint256 lvrControlNtl;
        uint256 lvrHardNtl;
    }

    string internal constant HEADER = "t,spot,bid,ask,mark,oracle,deskBid,deskAsk,lean,dislocationBps,"
        "mapBelowNtl,mapAboveNtl,forcedSellNtl,forcedBuyNtl,baseDesk,quoteDesk,baseControl,quoteControl,"
        "pnlDeskBps,pnlControlBps,absorbedDeskNtl,absorbedControlNtl,arbDeskNtl,arbControlNtl,"
        "markoutDesk5mBps,markoutDesk15mBps,markoutDesk60mBps,"
        "markoutControl5mBps,markoutControl15mBps,markoutControl60mBps,"
        "baseHard,quoteHard,pnlHardBps,absorbedHardNtl,arbHardNtl,"
        "markoutHard5mBps,markoutHard15mBps,markoutHard60mBps,"
        "absorbedTouchNtl,markoutTouch5mBps,markoutTouch15mBps,markoutTouch60mBps,"
        "lvrDeskNtl,lvrControlNtl,lvrHardNtl";

    string internal constant TAPE = "tape/oct10_btc_1m.json";
    string internal constant STUB_TAPE = "tape/oct10_btc_1m.stub.json";
    string internal constant OUT = "results/oct10_replay.csv";
    string internal constant SOURCE = "results/oct10_replay.source";

    /// @dev The markout horizons, in minutes. keeper/coldcascade/tape.py mirrors them in
    ///      MARKOUT_HORIZONS_MINUTES and cuts the tape's tail from the longest.
    uint256 internal constant MARKOUT_5M = 5;
    uint256 internal constant MARKOUT_15M = 15;
    uint256 internal constant MARKOUT_60M = 60;
    uint256 internal constant LONGEST_MARKOUT = MARKOUT_60M;

    /// @dev What an arbitrageur has to clear before it is worth being in the block: gas, fees, and
    ///      the risk of being second. Below it a dislocation is left standing, which is why a maker
    ///      drifts between minutes rather than tracking the touch exactly.
    uint16 internal constant ARB_EDGE_BPS = 10;

    /// @dev The share of the minute's forced notional that reaches a two-maker book at all. **A
    ///      parameter of the tape, never of a regime** — the same pot is offered in the quiet as in
    ///      a cascade, and who ends up with it is settled by price. This is the line the previous
    ///      placeholder got wrong, and getting it wrong was worth a factor of four.
    uint16 internal constant FLOW_CAPTURE_BPS = 10;

    /// @dev How finely the forced seller walks the book, and how many times inside one minute the
    ///      arbitrageur gets a look before the rest of the flow lands.
    ///
    ///      Interleaving is the honest middle. Give the arb the whole minute first and a stale
    ///      maker is always repriced before the flow arrives; give the flow the whole minute first
    ///      and in a falling market the stale maker always has the best bid, because last minute's
    ///      price was higher — the forced seller then captures the staleness itself instead of the
    ///      arbitrageur, and the desk, which will never bid above L1's ask, wins nothing. Both are
    ///      assumptions about queue position. This one asserts only that the arb gets *a* look
    ///      inside the minute, which is what a latency-optimised searcher does and a liquidated
    ///      account does not.
    uint256 internal constant FLOW_CLIPS = 30;
    uint256 internal constant FLOW_SLICES = 1;

    /// @dev 40 UBTC each. The quote leg is **not** a constant: it is set from the tape's first spot
    ///      so that XYCSwap's marginal price opens on the market. See `openingQuote`.
    uint256 internal constant START_BASE = 40e8;

    uint256 internal constant DESK = 0;
    uint256 internal constant CONTROL = 1;
    uint256 internal constant HARD = 2;

    /// @notice The maker fee on the third line, in the router's own unit: `Fee` uses `BPS = 1e9`,
    ///         so this is **30 bps**, near what a real BTC/USDT pool charges.
    ///
    /// @dev The plain control is the right ablation and the wrong competitor — it is `desk()` minus
    ///      one instruction, which isolates that instruction perfectly, and it is also a zero-fee
    ///      constant product on a BTC pair, which nobody ships. This line is the competitor, built
    ///      out of 1inch's own `Fee` instruction rather than an AMM written here, because a control
    ///      you wrote yourself is a foil and the first question about it is whether you tuned it to
    ///      lose.
    ///
    ///      The point is not that the fee is the right fee. It is that **it does not matter**: the
    ///      control's problem is that its price was set before the trade, and a fee schedule does
    ///      not touch that. `results/oct10_replay.source` carries the numbers at other settings.
    uint32 internal constant HARD_FEE_BPS = 3_000_000;

    uint256 internal startValue;
    DeskParams internal params;

    /// @dev Per minute, per line. Written by `drive` and read by the markout pass and the CSV.
    Fill[][] internal fills;
    Bleed[][] internal bleeds;

    /// @notice What Aqua held for each line at the close of each minute.
    /// @dev Snapshotted inside the loop, never read back afterwards. A balance read after the run
    ///      is the *final* balance, and writing that into every row draws two makers that were
    ///      fully invested from the first minute — a mistake the chart hides rather than shows.
    struct Held {
        uint256 base;
        uint256 quote;
    }

    Held[][] internal held;

    // ---- the gate that makes the rest of the file mean anything ----

    /// @notice Ship the same program into both slots and the two lines have to come out on top of
    ///         each other.
    ///
    ///         This is the first test in the file because every other number here is worth exactly
    ///         what it is worth. The claim is that the desk absorbs more because it *quoted* better,
    ///         and the only way to know the harness is not simply handing it more is to give the
    ///         two slots nothing to tell apart and check that nothing does. A taker that branches on
    ///         index, breaks a tie by position, or reads anything off a maker beyond the number that
    ///         came back from `quote` separates these two lines and fails here.
    ///
    /// @dev It is an exact equality, and it can be, because identical curves quoted one clip at a
    ///      time do not tie forever — the first fill moves the winner's curve and the next clip goes
    ///      to the next maker, so the makers take strict turns. The one thing that breaks that is
    ///      arithmetic rather than blindness: a minute's clips have to divide evenly among the
    ///      makers or the remainder lands somewhere, which is a granularity floor and not a leak.
    ///      So the divisibility is asserted first and the shares are then required to be equal to
    ///      the dollar, which is a far sharper instrument than a tolerance that would wave a real
    ///      two-percent leak through.
    function test_takers_areBlind() public {
        (Tick[] memory tape,) = loadTape();
        Line[] memory lines = shipLines(tape[0].spot, true);
        drive(tape, lines);

        uint256 absorbed;
        uint256 arbed;
        for (uint256 i = 0; i < lines.length; ++i) {
            emit log_named_uint("absorbed, slot (USD)", absorbedBy(i));
            emit log_named_uint("arb notional, slot (USD)", arbNotionalBy(i));
            absorbed += absorbedBy(i);
            arbed += arbNotionalBy(i);
        }
        assertGt(absorbed, 0, "identical makers absorbed nothing: the harness is not routing");
        assertGt(arbed, 0, "identical AMMs were never arbitraged: the arb is not searching");

        assertEq(FLOW_CLIPS % lines.length, 0, "the clips have to divide among the makers or the remainder is noise");
        for (uint256 i = 1; i < lines.length; ++i) {
            assertEq(absorbedBy(i), absorbedBy(0), "identical programs took different flow: a taker can see the maker");
            assertEq(arbNotionalBy(i), arbNotionalBy(0), "identical programs were arbitraged differently: same leak");
        }
    }

    // ---- the run ----

    function test_replay_writesResults() public {
        (Tick[] memory tape, bool isRealTape) = loadTape();
        assertGt(tape.length, 0, "the tape is empty");

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

    /// @notice Both makers open with XYCSwap's marginal price on the market, and this is the
    ///         assertion that says so.
    ///
    /// @dev A constant-product maker's marginal price is `quote / base`. Ship 40 UBTC against a
    ///      round 5 000 000 USDT0 and that is a raw 1 250 000 against a tape opening at 1 149 550 —
    ///      the control starts quoting **8.7 % over the market**, and under a taker that routes on
    ///      price it wins every forced sale until an arbitrageur has walked it down. The screen
    ///      then shows a badly initialised pool rather than a mechanism, and it shows it in the
    ///      control's favour, which is the direction nobody would think to check.
    ///
    ///      So the opening quote leg comes off the tape, and the tolerance is one raw tick.
    function test_openingInventory_isOnTheMarket() public {
        (Tick[] memory tape,) = loadTape();
        uint256 spot0 = tape[0].spot;
        uint256 quote_ = openingQuote(spot0);

        DeskParams memory p = btcParams();
        uint256 marginal = quote_ * p.pxDen / (START_BASE * p.pxNum);

        emit log_named_uint("tape opens at raw spot", spot0);
        emit log_named_uint("opening quote leg (USDT0)", quote_);
        emit log_named_uint("XYCSwap marginal price at open", marginal);

        assertApproxEqAbs(marginal, spot0, 1, "the curve must open on the market, not above it");
    }

    /// @dev The tape has to outlive its own last fill by the longest markout horizon, or
    ///      `markoutDesk60mBps` is structurally zero for every fill the desk made and the screen
    ///      shows only the half of the trade that loses.
    ///
    ///      The fix when this fails is a longer tape, never a shorter horizon.
    function test_tape_coversTheLongestMarkout() public {
        (Tick[] memory tape,) = loadTape();
        Row[] memory rows = run(tape);

        bool anyFill;
        uint256 lastFill;
        for (uint256 i = 0; i < rows.length; ++i) {
            if (filled(i, DESK) || filled(i, CONTROL)) {
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
            if (!filled(i, DESK)) continue;
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

    /// @notice The second gate, and it is not the death metric.
    ///
    ///         §2.5 asks whether one swap's amountOut responds to the book. A desk can pass that
    ///         and still draw two flat lines, because responding to the regime is not the same
    ///         claim as coming out ahead of the maker that ignores it.
    ///
    ///         This asks the other question: over the session, does what the desk absorbed
    ///         actually revert in its favour, by a multiple of what the control got?
    ///
    /// @dev When this fails, suspect the taker model before the quote — but only after
    ///      `test_takers_areBlind` has passed, because a taker that can see the maker will pass
    ///      this one for the wrong reason.
    function test_gate_absorbedEdgeBeatsControl() public {
        (Tick[] memory tape,) = loadTape();
        (int256 desk, int256 control) = absorbedEdge(run(tape));

        emit log_named_int("absorbed edge, desk (USD)", desk);
        emit log_named_int("absorbed edge, control (USD)", control);

        assertGt(desk, 0, "the desk lost money on what it absorbed: the lean is not paying for itself");
    }

    function absorbedOf(Row[] memory rows, uint256 line) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < rows.length; ++i) {
            n += line == DESK
                ? rows[i].absorbedDeskNtl
                : line == CONTROL ? rows[i].absorbedControlNtl : rows[i].absorbedHardNtl;
        }
    }

    function arbOf(Row[] memory rows, uint256 line) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < rows.length; ++i) {
            n += line == DESK ? rows[i].arbDeskNtl : line == CONTROL ? rows[i].arbControlNtl : rows[i].arbHardNtl;
        }
    }

    function lvrOf(Row[] memory rows, uint256 line) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < rows.length; ++i) {
            n += line == DESK ? rows[i].lvrDeskNtl : line == CONTROL ? rows[i].lvrControlNtl : rows[i].lvrHardNtl;
        }
    }

    function edgeOf(Row[] memory rows, uint256 line) internal pure returns (int256 n) {
        for (uint256 i = 0; i < rows.length; ++i) {
            (uint256 ntl, int256 bps) = line == DESK
                ? (rows[i].absorbedDeskNtl, rows[i].markoutDesk60mBps)
                : line == CONTROL
                    ? (rows[i].absorbedControlNtl, rows[i].markoutControl60mBps)
                    : (rows[i].absorbedHardNtl, rows[i].markoutHard60mBps);
            n += int256(ntl) * bps / 10_000;
        }
    }

    /// @notice The venue itself: the same forced flow, filled at L1's touch, marked out the same way.
    function touchEdge(Row[] memory rows) internal pure returns (int256 n) {
        for (uint256 i = 0; i < rows.length; ++i) {
            n += int256(rows[i].absorbedTouchNtl) * rows[i].markoutTouch60mBps / 10_000;
        }
    }

    function touchAbsorbed(Row[] memory rows) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < rows.length; ++i) {
            n += rows[i].absorbedTouchNtl;
        }
    }

    /// @notice Each maker's markout weighted by what it actually absorbed, summed over the
    ///         session, in USD. `markoutBps` is a rate; this is the quantity the rate is a rate *of*.
    function absorbedEdge(Row[] memory rows) internal pure returns (int256 desk, int256 control) {
        for (uint256 i = 0; i < rows.length; ++i) {
            desk += int256(rows[i].absorbedDeskNtl) * rows[i].markoutDesk60mBps / 10_000;
            control += int256(rows[i].absorbedControlNtl) * rows[i].markoutControl60mBps / 10_000;
        }
    }

    // ---- the loop ----

    function run(Tick[] memory tape) internal returns (Row[] memory rows) {
        Line[] memory lines = shipLines(tape[0].spot, false);
        drive(tape, lines);

        rows = new Row[](tape.length);
        for (uint256 i = 0; i < tape.length; ++i) {
            rows[i] = markToSpot(tape, i);
        }
        markouts(rows, tape);
    }

    /// @notice The minute loop itself, with no reporting in it, so that `test_takers_areBlind` can
    ///         drive exactly the same machine over a different pair of makers.
    function drive(Tick[] memory tape, Line[] memory lines) internal {
        fills = new Fill[][](tape.length);
        bleeds = new Bleed[][](tape.length);
        held = new Held[][](tape.length);

        for (uint256 i = 0; i < tape.length; ++i) {
            fills[i] = new Fill[](lines.length);
            bleeds[i] = new Bleed[](lines.length);
            held[i] = new Held[](lines.length);

            Tick memory tick = tape[i];
            vm.warp(tick.t);
            setBook(tick.bid, tick.ask, tick.mark, tick.oracle);
            mapOracle.update(BTC, uint128(tick.forcedSellNtl), uint128(tick.forcedBuyNtl));

            Market memory m = market(tick);
            Fill[] memory f = fills[i];
            Bleed[] memory b = bleeds[i];

            uint256 sellIn = legBase(m, tick.forcedSellNtl * FLOW_CAPTURE_BPS / BPS_DEN * 1e6, uint64(tick.spot));
            uint256 buyIn = tick.forcedBuyNtl * FLOW_CAPTURE_BPS / BPS_DEN * 1e6;

            for (uint256 s = 0; s < FLOW_SLICES; ++s) {
                runArb(lines, b, m, ARB_EDGE_BPS);
                routeFlow(lines, f, m, true, sellIn / FLOW_SLICES, FLOW_CLIPS / FLOW_SLICES, i + s);
                routeFlow(lines, f, m, false, buyIn / FLOW_SLICES, FLOW_CLIPS / FLOW_SLICES, i + s);
            }

            _store(i, f, b);
            for (uint256 k = 0; k < lines.length; ++k) {
                (uint256 base_, uint256 quote_) =
                    aqua.safeBalances(maker, address(swapVM), lines[k].hash, m.base, m.quote);
                held[i][k] = Held({ base: base_, quote: quote_ });
            }
        }
    }

    /// @dev Memory rows written back to storage, because the markout pass and the CSV need minutes
    ///      the loop has already left behind.
    function _store(uint256 i, Fill[] memory f, Bleed[] memory b) private {
        for (uint256 k = 0; k < f.length; ++k) {
            fills[i][k] = f[k];
            bleeds[i][k] = b[k];
        }
    }

    /// @notice Ship the two makers: the desk, and the same curve with the bound removed.
    /// @param twins true ships the control's program into both slots — the blindness test.
    function shipLines(uint256 spot0, bool twins) internal returns (Line[] memory lines) {
        params = btcParams();
        params.mapOracle = address(mapOracle);

        uint256 quote_ = openingQuote(spot0);
        startValue = valueAtSpot(START_BASE, quote_, spot0);

        lines = new Line[](3);
        ISwapVM.Order[3] memory os = twins
            ? [
                controlOrder(params, keccak256("twin-a")),
                controlOrder(params, keccak256("twin-b")),
                controlOrder(params, keccak256("twin-c"))
            ]
            : [
                deskOrder(params, keccak256("desk")),
                controlOrder(params, keccak256("control")),
                hardControlOrder(params, HARD_FEE_BPS, keccak256("hard"))
            ];

        for (uint256 i = 0; i < 3; ++i) {
            lines[i] = Line({ order: os[i], hash: shipFunded(os[i], params, START_BASE, quote_) });
        }
    }

    /// @notice The quote leg that puts XYCSwap's marginal price on the tape's opening spot.
    /// @dev `test_openingInventory_isOnTheMarket` is the assertion; this is the arithmetic.
    function openingQuote(uint256 spot0) internal view returns (uint256) {
        DeskParams memory p = btcParams();
        return START_BASE * spot0 * p.pxNum / p.pxDen;
    }

    function market(Tick memory tick) internal view returns (Market memory) {
        return Market({
            base: params.base,
            quote: params.quote,
            pxNum: params.pxNum,
            pxDen: params.pxDen,
            bid: tick.bid,
            ask: tick.ask,
            spot: tick.spot
        });
    }

    function loadTape() internal view returns (Tick[] memory tape, bool isRealTape) {
        isRealTape = vm.exists(TAPE);
        string memory path = isRealTape ? TAPE : STUB_TAPE;
        tape = abi.decode(vm.parseJson(vm.readFile(path)), (Tick[]));
    }

    // ---- reporting ----

    function markToSpot(Tick[] memory tape, uint256 i) internal returns (Row memory row) {
        Tick memory tick = tape[i];
        vm.warp(tick.t);
        setBook(tick.bid, tick.ask, tick.mark, tick.oracle);
        mapOracle.update(BTC, uint128(tick.forcedSellNtl), uint128(tick.forcedBuyNtl));

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

        // Inventory is Aqua's, not ours: the swaps actually moved it. Taken as of this minute's
        // close, which is why `drive` snapshots it rather than this pass reading it back.
        (row.baseDesk, row.quoteDesk) = (held[i][DESK].base, held[i][DESK].quote);
        (row.baseControl, row.quoteControl) = (held[i][CONTROL].base, held[i][CONTROL].quote);

        (row.baseHard, row.quoteHard) = (held[i][HARD].base, held[i][HARD].quote);

        row.pnlDeskBps = pnlBps(row.baseDesk, row.quoteDesk, tick.spot);
        row.pnlControlBps = pnlBps(row.baseControl, row.quoteControl, tick.spot);
        row.pnlHardBps = pnlBps(row.baseHard, row.quoteHard, tick.spot);
        row.absorbedDeskNtl = absorbedAt(i, DESK);
        row.absorbedControlNtl = absorbedAt(i, CONTROL);
        row.absorbedHardNtl = absorbedAt(i, HARD);
        row.arbDeskNtl = bleeds[i][DESK].notional;
        row.arbControlNtl = bleeds[i][CONTROL].notional;
        row.arbHardNtl = bleeds[i][HARD].notional;
        row.lvrDeskNtl = bleeds[i][DESK].profit;
        row.lvrControlNtl = bleeds[i][CONTROL].profit;
        row.lvrHardNtl = bleeds[i][HARD].profit;
        row.absorbedTouchNtl = (tick.forcedSellNtl + tick.forcedBuyNtl) * FLOW_CAPTURE_BPS / BPS_DEN;
        // The markout columns are a second pass: they need minutes this one has not seen yet.
    }

    /// @dev A markout is the later spot against the price the minute filled at, **signed by the
    ///      side the maker took**: a maker that bought is right when the price goes up and a maker
    ///      that sold is right when it goes down. Weighted by notional when a minute filled both
    ///      ways. Minutes with no fill, and minutes the tape does not reach past, are zero.
    function markouts(Row[] memory rows, Tick[] memory tape) internal view {
        for (uint256 i = 0; i < rows.length; ++i) {
            rows[i].markoutDesk5mBps = markoutAt(tape, i, DESK, MARKOUT_5M);
            rows[i].markoutDesk15mBps = markoutAt(tape, i, DESK, MARKOUT_15M);
            rows[i].markoutDesk60mBps = markoutAt(tape, i, DESK, MARKOUT_60M);
            rows[i].markoutControl5mBps = markoutAt(tape, i, CONTROL, MARKOUT_5M);
            rows[i].markoutControl15mBps = markoutAt(tape, i, CONTROL, MARKOUT_15M);
            rows[i].markoutControl60mBps = markoutAt(tape, i, CONTROL, MARKOUT_60M);
            rows[i].markoutHard5mBps = markoutAt(tape, i, HARD, MARKOUT_5M);
            rows[i].markoutHard15mBps = markoutAt(tape, i, HARD, MARKOUT_15M);
            rows[i].markoutHard60mBps = markoutAt(tape, i, HARD, MARKOUT_60M);
            rows[i].markoutTouch5mBps = touchMarkout(tape, i, MARKOUT_5M);
            rows[i].markoutTouch15mBps = touchMarkout(tape, i, MARKOUT_15M);
            rows[i].markoutTouch60mBps = touchMarkout(tape, i, MARKOUT_60M);
        }
    }

    /// @notice The fourth line, and the only one nobody can call rigged: the same forced flow,
    ///         filled at Hyperliquid's own touch.
    ///
    /// @dev It is not a maker. It holds no inventory, it is never arbitraged, and it takes the whole
    ///      pot rather than competing for it — it is the answer to "compared to what?" when the
    ///      answer "compared to an AMM" is not good enough, because the benchmark is the venue the
    ///      desk quotes against and the price is a column of the tape rather than anything computed
    ///      here. A maker that cannot beat it per dollar absorbed has no business existing.
    function touchMarkout(Tick[] memory tape, uint256 i, uint256 horizon) internal pure returns (int256) {
        if (i + horizon >= tape.length) return 0;
        Tick memory tick = tape[i];
        int256 later = int256(tape[i + horizon].spot);

        // Forced selling is taken on L1's bid; forced buying is filled on L1's ask.
        if (tick.forcedSellNtl != 0) {
            int256 px = int256(uint256(tick.bid));
            return (later - px) * 10_000 / px;
        }
        if (tick.forcedBuyNtl != 0) {
            int256 px = int256(uint256(tick.ask));
            return -((later - px) * 10_000 / px);
        }
        return 0;
    }

    function markoutAt(Tick[] memory tape, uint256 i, uint256 line, uint256 horizon)
        internal
        view
        returns (int256)
    {
        if (i + horizon >= tape.length) return 0;
        Fill memory f = fills[i][line];
        int256 later = int256(tape[i + horizon].spot);

        int256 acc;
        uint256 weight;
        if (f.boughtBase != 0 && f.paidQuote != 0) {
            int256 px = int256(f.paidQuote * params.pxDen / (f.boughtBase * params.pxNum));
            acc += (later - px) * 10_000 / px * int256(f.paidQuote);
            weight += f.paidQuote;
        }
        if (f.soldBase != 0 && f.gotQuote != 0) {
            int256 px = int256(f.gotQuote * params.pxDen / (f.soldBase * params.pxNum));
            acc -= (later - px) * 10_000 / px * int256(f.gotQuote);
            weight += f.gotQuote;
        }
        return weight == 0 ? int256(0) : acc / int256(weight);
    }

    function absorbedAt(uint256 i, uint256 line) internal view returns (uint256) {
        Fill memory f = fills[i][line];
        return (f.paidQuote + f.gotQuote) / 1e6;
    }

    function filled(uint256 i, uint256 line) internal view returns (bool) {
        Fill memory f = fills[i][line];
        return f.paidQuote != 0 || f.gotQuote != 0;
    }

    function absorbedBy(uint256 line) internal view returns (uint256 total) {
        for (uint256 i = 0; i < fills.length; ++i) {
            total += absorbedAt(i, line);
        }
    }

    function arbNotionalBy(uint256 line) internal view returns (uint256 total) {
        for (uint256 i = 0; i < bleeds.length; ++i) {
            total += bleeds[i][line].notional;
        }
    }

    function arbProfitBy(uint256 line) internal view returns (uint256 total) {
        for (uint256 i = 0; i < bleeds.length; ++i) {
            total += bleeds[i][line].profit;
        }
    }

    // ---- writing ----

    function writeResults(Row[] memory rows, Tick[] memory tape, bool isRealTape) internal {
        vm.writeFile(OUT, string.concat(HEADER, "\n"));
        for (uint256 i = 0; i < rows.length; ++i) {
            vm.writeLine(OUT, csv(rows[i]));
        }

        string memory path = isRealTape ? TAPE : STUB_TAPE;
        vm.writeFile(
            SOURCE,
            string.concat(
                "tape: ", path, "\n",
                "keccak256: ", vm.toString(keccak256(bytes(vm.readFile(path)))), "\n",
                "ticks: ", vm.toString(tape.length), "\n",
                "takers: blind (router quotes; arb closed at L1's touch, then the forced flow)\n",
                "hard control fee: ", vm.toString(HARD_FEE_BPS), " of 1e9\n\n",
                _lineStamp("desk", rows, DESK),
                _lineStamp("control (XYCSwap)", rows, CONTROL),
                _lineStamp("control (XYCSwap, fee)", rows, HARD),
                "L1 touch (benchmark)  absorbed ", vm.toString(touchAbsorbed(rows)),
                "  edge60 ", vm.toString(touchEdge(rows)),
                "  lvr 0  arb notional 0\n"
            )
        );
    }

    /// @dev One line's session totals, in whole USD. `absorbed` is what the forced seller gave it,
    ///      `edge60` is that notional times its own 60 minute markout, `lvr` is what the
    ///      arbitrageur took out of it at L1's touch, and `net` is the only one of the four that a
    ///      maker would recognise as the answer.
    function _lineStamp(string memory name, Row[] memory rows, uint256 line)
        private
        pure
        returns (string memory)
    {
        int256 edge = edgeOf(rows, line);
        int256 lvr = int256(lvrOf(rows, line));
        return string.concat(
            name,
            "  absorbed ", vm.toString(absorbedOf(rows, line)),
            "  edge60 ", vm.toString(edge),
            "  lvr ", vm.toString(lvr),
            "  arb notional ", vm.toString(arbOf(rows, line)),
            "  net ", vm.toString(edge - lvr),
            "\n"
        );
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
            ",", _i(r.markoutControl5mBps), ",", _i(r.markoutControl15mBps), ",", _i(r.markoutControl60mBps),
            ",", _csvTail(r)
        );
    }

    /// @dev The three lines added after the schema was first frozen, split out so `csv` stays
    ///      inside the stack.
    function _csvTail(Row memory r) private pure returns (string memory) {
        return string.concat(
            _u(r.baseHard), ",", _u(r.quoteHard), ",", _i(r.pnlHardBps),
            ",", _u(r.absorbedHardNtl), ",", _u(r.arbHardNtl),
            ",", _i(r.markoutHard5mBps), ",", _i(r.markoutHard15mBps), ",", _i(r.markoutHard60mBps),
            ",", _u(r.absorbedTouchNtl),
            ",", _i(r.markoutTouch5mBps), ",", _i(r.markoutTouch15mBps), ",", _i(r.markoutTouch60mBps),
            ",", _u(r.lvrDeskNtl), ",", _u(r.lvrControlNtl), ",", _u(r.lvrHardNtl)
        );
    }

    // ---- marks ----

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
