// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { DeskTest } from "./base/DeskTest.sol";
import { DeskAccount } from "../src/DeskAccount.sol";
import { DeskHooks } from "../src/DeskHooks.sol";
import { ICoreReader, Book } from "../src/interfaces/ICoreReader.sol";
import { DeskParams, DeskParamsLib } from "../src/libs/DeskParams.sol";
import { DeskPrograms } from "../src/libs/DeskPrograms.sol";
import { Side } from "../src/libs/Regime.sol";

/// @notice The hook is how the L1 book becomes an EVM log. Everything the markout needs is in the
///         `Fill` event, so a later join needs the subgraph and nothing else — no archive node, no
///         replaying a quote against a book that has since moved.
contract DeskHooksTest is DeskTest {
    bytes32 internal constant SALT = keccak256("hooks");
    uint256 internal constant ONE_UBTC = 1e8;
    uint256 internal constant START_BASE = 10e8;
    /// @dev Deliberately quote-heavy: the constant product on 10 UBTC against 900 000 USDT0 prices
    ///      a 1 UBTC fill above the book, so the book bound is what settles the price and the event
    ///      is about a fill the desk actually chose. See CoreQuoteTest for the other side of the min.
    uint256 internal constant START_QUOTE = 900_000e6;

    event MakerCallFailed(bytes32 indexed orderHash, address indexed maker);

    /// @dev A dislocated book, so the fill is on the absorbing side and the hedge branch runs.
    uint64 internal constant WIDE_BID = 780_000;
    uint64 internal constant WIDE_ASK = 790_000;
    uint64 internal constant WIDE_MARK = 782_000;

    event Fill(
        bytes32 indexed orderHash,
        address indexed maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint64 bid,
        uint64 ask,
        uint64 mark,
        uint64 oracle,
        uint128 mapBelow,
        uint128 mapAbove
    );

    /// @dev The four book words in the log are the ones the quote priced against, in the same
    ///      transaction. That is the whole point: a fill and its book cannot drift apart.
    function test_fill_emitsBookState() public {
        DeskParams memory p = btcParams();
        p.mapOracle = address(mapOracle);
        mapOracle.update(BTC, 9_000_000, 0);

        ISwapVM.Order memory o = deskOrder(p, SALT);
        bytes32 orderHash = shipFunded(o, p, START_BASE, START_QUOTE);
        (, uint256 expectedOut) = quoteRouter(o, p, ONE_UBTC, true, true);
        fundTaker(o, p, ONE_UBTC, true, true);

        vm.expectEmit(true, true, true, true, address(hooks));
        emit Fill(
            orderHash,
            maker,
            address(taker),
            address(ubtc),
            address(usdt0),
            ONE_UBTC,
            expectedOut,
            QUIET_BID,
            QUIET_ASK,
            QUIET_MARK,
            QUIET_ORACLE,
            9_000_000,
            0
        );
        swapOnly(o, p, ONE_UBTC, true, true);
    }

    /// @dev The event is a claim about a swap the router settled. Anyone could otherwise write the
    ///      subgraph's history by calling the hook directly.
    function test_fill_onlyRouter() public {
        vm.expectRevert(abi.encodeWithSelector(DeskHooks.OnlyRouter.selector, address(this)));
        hooks.postTransferOut(
            maker, address(taker), address(ubtc), address(usdt0), 1, 1, 0, bytes32(0), hookData(btcParams()), ""
        );
    }

    /// @dev CoreQuote is `view` because the quote path never reaches a contract that writes. Proven
    ///      by pointing the hook at something that always reverts: the quote still answers, the
    ///      swap does not settle.
    function test_quotePath_neverCallsHook() public {
        DeskParams memory p = btcParams();
        ISwapVM.Order memory o =
            DeskPrograms.order(maker, address(new RevertingHooks()), DeskPrograms.deskWithSalt(address(coreQuote), p, SALT), p);
        shipFunded(o, p, START_BASE, START_QUOTE);

        (, uint256 out) = quoteRouter(o, p, ONE_UBTC, true, true);
        assertEq(out, ONE_UBTC * QUIET_BID * (10_000 - QUIET_BPS) / 10_000_000, "the quote never reached the hook");

        fundTaker(o, p, ONE_UBTC, true, true);
        vm.expectRevert(RevertingHooks.HookRan.selector);
        taker.swap(o, ONE_UBTC, takerData(address(taker), true, isAToB(p, true)));
    }

    /// @dev Nothing after the transfer may fail the transfer. A reader that reverts leaves the book
    ///      columns at zero -- which an indexer can see and skip -- and the fill still settles.
    function test_fill_unreadableBook_stillSettles() public {
        DeskParams memory p = btcParams();
        DeskHooks blind = new DeskHooks(address(swapVM), new RevertingReader());
        ISwapVM.Order memory o =
            DeskPrograms.order(maker, address(blind), DeskPrograms.deskWithSalt(address(coreQuote), p, SALT), p);
        bytes32 orderHash = shipFunded(o, p, START_BASE, START_QUOTE);
        (, uint256 expectedOut) = quoteRouter(o, p, ONE_UBTC, true, true);
        fundTaker(o, p, ONE_UBTC, true, true);

        vm.expectEmit(true, true, true, true, address(blind));
        emit Fill(
            orderHash, maker, address(taker), address(ubtc), address(usdt0), ONE_UBTC, expectedOut, 0, 0, 0, 0, 0, 0
        );
        swapOnly(o, p, ONE_UBTC, true, true);

        assertEq(usdt0.balanceOf(address(taker)), expectedOut, "the taker was paid all the same");
    }

    /// @dev A stale map is not in the event as a lean; it is in the event as the numbers that were
    ///      on chain when the fill happened. Deciding what stale means is the quote's job, and the
    ///      indexer can redo it from `updatedAt`.
    function test_fill_carriesMapEvenWhenStale() public {
        DeskParams memory p = btcParams();
        p.mapOracle = address(mapOracle);
        mapOracle.update(BTC, 9_000_000, 4_000_000);
        vm.warp(block.timestamp + MAP_MAX_AGE + 1);

        ISwapVM.Order memory o = deskOrder(p, SALT);
        bytes32 orderHash = shipFunded(o, p, START_BASE, START_QUOTE);
        (, uint256 expectedOut) = quoteRouter(o, p, ONE_UBTC, true, true);
        fundTaker(o, p, ONE_UBTC, true, true);

        vm.expectEmit(true, true, true, true, address(hooks));
        emit Fill(
            orderHash,
            maker,
            address(taker),
            address(ubtc),
            address(usdt0),
            ONE_UBTC,
            expectedOut,
            QUIET_BID,
            QUIET_ASK,
            QUIET_MARK,
            QUIET_ORACLE,
            9_000_000,
            4_000_000
        );
        swapOnly(o, p, ONE_UBTC, true, true);
    }

    // ---- the maker callback: a hedge can never fail a fill ----

    /// @dev The sentence this is worth more than the hedge for. A maker account that reverts on
    ///      every fill still gets filled; the failure is a log, not an unwind.
    function test_makerCallback_revertCannotFailAFill() public {
        (ISwapVM.Order memory o, DeskParams memory p, uint256 expectedOut) = shipFromMaker(address(new AngryDesk()));

        vm.expectEmit(true, true, true, true, address(hooks));
        emit MakerCallFailed(swapVM.hash(o), o.maker);
        swapOnly(o, p, ONE_UBTC, true, true);

        assertEq(usdt0.balanceOf(address(taker)), expectedOut, "the taker was paid");
    }

    /// @dev And a maker that tries to burn the taker's whole budget is stopped at the cap. Without
    ///      it, the 1/64 EIP-150 leaves behind is not a guarantee that the transaction finishes.
    ///      Measured 2026-09-05: 374 478 gas for the whole swap against a maker burning everything
    ///      it is handed, of which 250 000 is the cap.
    function test_makerCallback_gasIsCapped() public {
        (ISwapVM.Order memory o, DeskParams memory p,) = shipFromMaker(address(new GreedyDesk()));

        uint256 before = gasleft();
        swapOnly(o, p, ONE_UBTC, true, true);
        uint256 spent = before - gasleft();

        emit log_named_uint("swap gas against a maker burning everything it is given", spent);
        assertLt(spent, 250_000 + 200_000, "the cap plus the swap is the ceiling, not the taker's whole budget");
    }

    /// @dev An EOA maker is never called: `maker.code.length` is zero and the branch is skipped.
    ///      The control strategy ships from one, so this is not a hypothetical.
    function test_makerCallback_eoaMakerIsNotCalled() public {
        DeskParams memory p = btcParams();
        ISwapVM.Order memory o = deskOrder(p, SALT);
        shipFunded(o, p, START_BASE, START_QUOTE);
        fundTaker(o, p, ONE_UBTC, true, true);

        vm.recordLogs();
        swapOnly(o, p, ONE_UBTC, true, true);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != MakerCallFailed.selector, "an EOA maker is not called at all");
        }
    }

    /// @dev What the callback costs a taker today, so the cap is a stated number and not a guess.
    ///      Measured 2026-09-05: 5 797 gas with the hedge armed and the fill on the absorbing side.
    ///      The CoreWriter leg it grows into is ~47 000 gas with 25 000 burned by HyperCore's docs,
    ///      `[UNVERIFIED]` against chain 999 until the 2026-09-07 probe.
    function test_onFill_costsWhatTheCapAllowsFor() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = openDesk(address(this), "measured", p, START_BASE, START_QUOTE);
        desk.armHedge(true, 500_000e6);
        setBook(WIDE_BID, WIDE_ASK, WIDE_MARK, QUIET_ORACLE);

        Book memory book = Book(WIDE_BID, WIDE_ASK, WIDE_MARK, QUIET_ORACLE);
        vm.prank(address(hooks));
        uint256 before = gasleft();
        desk.onFill(bytes32(uint256(1)), address(ubtc), address(usdt0), ONE_UBTC, 1, book, Side.Bid);
        uint256 spent = before - gasleft();

        emit log_named_uint("onFill gas, hedge armed and firing", spent);
        assertLt(spent, 20_000, "today's callback, with room left under the cap for the CoreWriter leg");
    }

    // ---- helpers ----

    /// @dev Ships the canonical desk program from `deskMaker`, funds both sides and the taker, and
    ///      returns what the quote says the fill will pay.
    function shipFromMaker(address deskMaker)
        internal
        returns (ISwapVM.Order memory o, DeskParams memory p, uint256 expectedOut)
    {
        p = btcParams();
        o = DeskPrograms.order(deskMaker, address(hooks), DeskPrograms.deskWithSalt(address(coreQuote), p, SALT), p);

        ubtc.mint(deskMaker, START_BASE);
        usdt0.mint(deskMaker, START_QUOTE);
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (START_BASE, START_QUOTE);

        vm.startPrank(deskMaker);
        ubtc.approve(address(aqua), type(uint256).max);
        usdt0.approve(address(aqua), type(uint256).max);
        aqua.ship(address(swapVM), DeskPrograms.strategyBytes(o), DeskPrograms.tokens(p), amounts);
        vm.stopPrank();

        (, expectedOut) = quoteRouter(o, p, ONE_UBTC, true, true);
        fundTaker(o, p, ONE_UBTC, true, true);
    }

    function hookData(DeskParams memory p) internal pure returns (bytes memory) {
        return DeskParamsLib.encode(p);
    }
}

contract RevertingHooks {
    error HookRan();

    fallback() external {
        revert HookRan();
    }
}

contract RevertingReader is ICoreReader {
    error NoBook();

    function read(uint32) external pure returns (Book memory) {
        revert NoBook();
    }
}

/// @notice A maker account that reverts on every fill callback.
contract AngryDesk {
    error Angry();

    function onFill(bytes32, address, address, uint256, uint256, Book calldata, uint8) external pure {
        revert Angry();
    }
}

/// @notice A maker account that burns whatever gas it is given.
contract GreedyDesk {
    uint256 public sink;

    function onFill(bytes32, address, address, uint256, uint256, Book calldata, uint8) external {
        while (true) {
            sink++;
        }
    }
}
