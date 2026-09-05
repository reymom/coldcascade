// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { DeskTest } from "./base/DeskTest.sol";
import { DeskHooks } from "../src/DeskHooks.sol";
import { ICoreReader, Book } from "../src/interfaces/ICoreReader.sol";
import { DeskParams, DeskParamsLib } from "../src/libs/DeskParams.sol";
import { DeskPrograms } from "../src/libs/DeskPrograms.sol";

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
            maker, address(taker), address(ubtc), address(usdt0), 1, 1, bytes32(0), hookData(btcParams()), ""
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
        (address tokenIn, address tokenOut) = pair(p, true);
        taker.swap(o, tokenIn, tokenOut, ONE_UBTC, deskTakerData(address(taker), true, false));
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

    // ---- the hook emits the fill and stops ----

    /// @dev The strongest form of "a maker that reverts still gets its fill": the hook does not
    ///      call the maker at all, so there is nothing to revert. A contract whose every entry
    ///      point throws is still a maker.
    function test_makerIsNeverCalled_evenWhenItWouldRevert() public {
        (ISwapVM.Order memory o, DeskParams memory p, uint256 expectedOut) = shipFromMaker(address(new AngryDesk()));

        swapOnly(o, p, ONE_UBTC, true, true);

        assertEq(usdt0.balanceOf(address(taker)), expectedOut, "the taker was paid");
        assertEq(ubtc.balanceOf(o.maker), START_BASE + ONE_UBTC, "and the maker holds what it bought");
    }

    /// @dev A maker feature is not a taker cost. Two swaps identical but for the maker being a
    ///      contract that would burn everything it was handed cost the taker the same gas, because
    ///      neither maker is handed anything.
    /// @dev A warm-up swap first, against a third maker: the taker's own token slots are cold on
    ///      the first swap of a test and that dominates a 5 797 gas question. After it, the two
    ///      measured swaps differ only in who the maker is.
    function test_contractMakerCostsTheTakerNothingExtra() public {
        DeskParams memory p = btcParams();
        warmUp(p);

        (ISwapVM.Order memory greedy,,) = shipFromMaker(address(new GreedyDesk()));
        uint256 before = gasleft();
        swapOnly(greedy, p, ONE_UBTC, true, true);
        uint256 againstContract = before - gasleft();

        ISwapVM.Order memory eoa = deskOrder(p, keccak256("eoa"));
        shipFunded(eoa, p, START_BASE, START_QUOTE);
        fundTaker(eoa, p, ONE_UBTC, true, true);
        before = gasleft();
        swapOnly(eoa, p, ONE_UBTC, true, true);
        uint256 againstEoa = before - gasleft();

        emit log_named_uint("swap gas, contract maker", againstContract);
        emit log_named_uint("swap gas, EOA maker", againstEoa);

        // Measured 2026-09-05: 97 966 against the contract, 97 993 against the EOA. The contract is
        // the cheaper of the two, so there is no callback left in the bill; what is left is calldata
        // noise, the two maker addresses having a different number of zero bytes. Both moved up by
        // ~4 600 from the earlier figure, half of it the optimizer coming down to 200 runs so the
        // deployment fits a HyperEVM small block and half the move to the SwapVM revision actually
        // deployed on 999 — results/999_deploy_budget.md and results/999_router_abi.md.
        assertLe(againstContract, againstEoa, "a contract maker is not the more expensive one to fill");
        assertLt(againstEoa - againstContract, 100, "and what is left is not a callback");
    }

    // ---- helpers ----

    /// @dev One throwaway swap so the taker's token slots and the router's accounts are warm.
    function warmUp(DeskParams memory p) internal {
        ISwapVM.Order memory o = deskOrder(p, keccak256("warmup"));
        shipFunded(o, p, START_BASE, START_QUOTE);
        swapRouter(o, p, ONE_UBTC, true, true);
    }

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

/// @notice A maker account that rejects every call it receives. Being filled is not a call.
contract AngryDesk {
    error Angry();

    fallback() external {
        revert Angry();
    }
}

/// @notice A maker account that would burn whatever gas it were given, if it were given any.
contract GreedyDesk {
    uint256 public sink;

    fallback() external {
        while (true) {
            sink++;
        }
    }
}
