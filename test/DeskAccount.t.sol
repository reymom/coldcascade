// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { DeskTest } from "./base/DeskTest.sol";
import { DeskAccount } from "../src/DeskAccount.sol";
import { DeskFactory } from "../src/DeskFactory.sol";
import { Book } from "../src/interfaces/ICoreReader.sol";
import { DeskParams } from "../src/libs/DeskParams.sol";
import { Side } from "../src/libs/Regime.sol";

/// @notice The desk is a contract the maker owns, not a vault and not an EOA. These are the four
///         claims that makes: it can ship, a taker can pull from it, its owner can close it in one
///         call and get everything back, and a parameter change is a dock and a fresh ship.
contract DeskAccountTest is DeskTest {
    uint256 internal constant ONE_UBTC = 1e8;
    uint256 internal constant START_BASE = 10e8;
    uint256 internal constant START_QUOTE = 900_000e6;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    // ---- open ----

    function test_open_shipsFromTheAccount() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = openDesk(alice, "ramon", p, START_BASE, START_QUOTE);

        assertEq(desk.owner(), alice, "the caller owns the desk, nobody else");
        assertEq(desk.label(), "ramon");
        assertTrue(desk.isOpen());
        assertEq(desk.shipCount(), 1);

        // The tokens are in the account, not in the factory and not in the wallet.
        assertEq(ubtc.balanceOf(address(desk)), START_BASE, "the account holds the base");
        assertEq(usdt0.balanceOf(address(desk)), START_QUOTE, "and the quote");
        assertEq(ubtc.balanceOf(alice), 0, "the wallet handed them over");
        assertEq(ubtc.balanceOf(address(factory)), 0, "the factory is never a custodian");

        // Aqua's balances are keyed by the account, and the strategy is the one `order()` rebuilds.
        (uint256 balanceBase, uint256 balanceQuote) =
            aqua.safeBalances(address(desk), address(swapVM), desk.strategyHash(), p.base, p.quote);
        assertEq(balanceBase, START_BASE);
        assertEq(balanceQuote, START_QUOTE);
        assertEq(desk.strategyHash(), swapVM.hash(desk.order()), "the account's own view of its order is the live one");
    }

    /// @dev The implementation is not a desk. Only the factory can initialize, and it only ever
    ///      calls its own clones, so the implementation stays ownerless forever.
    function test_open_implementationCannotBeSeized() public {
        DeskAccount implementation = DeskAccount(factory.IMPLEMENTATION());
        assertEq(implementation.owner(), address(0));

        vm.expectRevert(abi.encodeWithSelector(DeskAccount.OnlyFactory.selector, bob));
        vm.prank(bob);
        implementation.initialize(bob, "steal", btcParams(), 0, 0);
    }

    /// @dev Two desks from the same wallet with the same parameters are two objects with two
    ///      addresses and two strategy hashes. The salt is per account and per ship.
    function test_open_twoDesksSameParams() public {
        DeskParams memory p = btcParams();
        DeskAccount first = openDesk(alice, "one", p, START_BASE, START_QUOTE);
        DeskAccount second = openDesk(alice, "two", p, START_BASE, START_QUOTE);

        assertTrue(address(first) != address(second));
        assertTrue(first.strategyHash() != second.strategyHash(), "same parameters, different strategies");
    }

    // ---- a taker pulls from the account ----

    /// @dev Aqua's `pull` is a plain transferFrom from the maker, so a contract maker works only if
    ///      its approve is right. This is the one thing about the whole redesign that could not be
    ///      argued from the docs.
    function test_swap_pullsFromTheAccount() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = openDesk(alice, "ramon", p, START_BASE, START_QUOTE);
        ISwapVM.Order memory o = desk.order();

        (, uint256 quoted) = quoteRouter(o, p, ONE_UBTC, true, true);
        assertEq(quoted, ONE_UBTC * QUIET_BID * (10_000 - QUIET_BPS) / 10_000_000, "priced off the book, from a clone");

        (uint256 amountIn, uint256 amountOut) = swapRouter(o, p, ONE_UBTC, true, true);

        assertEq(amountOut, quoted, "what the quote said");
        assertEq(usdt0.balanceOf(address(taker)), amountOut, "the taker was paid out of the account");
        assertEq(usdt0.balanceOf(address(desk)), START_QUOTE - amountOut, "and the account is down exactly that");
        assertEq(ubtc.balanceOf(address(desk)), START_BASE + amountIn, "the base it bought landed in the account");
    }

    // ---- close ----

    function test_close_returnsEverything() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = openDesk(alice, "ramon", p, START_BASE, START_QUOTE);
        ISwapVM.Order memory o = desk.order();
        (uint256 amountIn, uint256 amountOut) = swapRouter(o, p, ONE_UBTC, true, true);

        vm.prank(alice);
        desk.close();

        assertFalse(desk.isOpen());
        assertEq(desk.strategyHash(), bytes32(0));
        assertEq(ubtc.balanceOf(alice), START_BASE + amountIn, "every base unit came home, fills included");
        assertEq(usdt0.balanceOf(alice), START_QUOTE - amountOut, "and every quote unit");
        assertEq(ubtc.balanceOf(address(desk)), 0, "the account keeps nothing");
        assertEq(usdt0.balanceOf(address(desk)), 0);
    }

    /// @dev Docked means unreachable: the router reads the balances from Aqua and Aqua refuses.
    function test_close_stopsTheStrategy() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = openDesk(alice, "ramon", p, START_BASE, START_QUOTE);
        ISwapVM.Order memory o = desk.order();
        fundTaker(o, p, ONE_UBTC, true, true);

        vm.prank(alice);
        desk.close();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAqua.SafeBalancesForTokenNotInActiveStrategy.selector,
                address(desk),
                address(swapVM),
                swapVM.hash(o),
                address(ubtc)
            )
        );
        swapOnly(o, p, ONE_UBTC, true, true);
    }

    function test_close_twiceReverts() public {
        DeskAccount desk = openDesk(alice, "ramon", btcParams(), START_BASE, START_QUOTE);
        vm.prank(alice);
        desk.close();

        vm.expectRevert(DeskAccount.NotOpen.selector);
        vm.prank(alice);
        desk.close();
    }

    // ---- reopen: the only kind of parameter change there is ----

    function test_reopen_isAParameterChange() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = openDesk(alice, "ramon", p, START_BASE, START_QUOTE);
        bytes32 firstHash = desk.strategyHash();
        (, uint256 quotedAt20Bps) = quoteRouter(desk.order(), p, ONE_UBTC, true, true);

        DeskParams memory wider = p;
        wider.quietBps = 60;
        vm.prank(alice);
        bytes32 secondHash = desk.reopen(wider, START_BASE, START_QUOTE);

        assertTrue(secondHash != firstHash, "a new strategy, because the parameters are in the hash");
        assertEq(desk.strategyHash(), secondHash);
        assertEq(desk.shipCount(), 2);
        assertEq(desk.params().quietBps, 60);

        (, uint256 quotedAt60Bps) = quoteRouter(desk.order(), wider, ONE_UBTC, true, true);
        assertLt(quotedAt60Bps, quotedAt20Bps, "the desk stepped further outside L1, as asked");

        // The old strategy is docked; only the new one is reachable.
        (uint256 balanceBase,) =
            aqua.safeBalances(address(desk), address(swapVM), secondHash, p.base, p.quote);
        assertEq(balanceBase, START_BASE, "the new strategy carries the inventory");
    }

    /// @dev Reopening with the parameters it already had is the ordinary case — a desk that was
    ///      closed for an hour and comes back. Aqua would refuse the repeated hash; the per-ship
    ///      salt is what makes it work, and this is the test that would catch losing it.
    function test_reopen_sameParamsStillShips() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = openDesk(alice, "ramon", p, START_BASE, START_QUOTE);
        bytes32 firstHash = desk.strategyHash();

        vm.prank(alice);
        bytes32 secondHash = desk.reopen(p, START_BASE, START_QUOTE);

        assertTrue(secondHash != firstHash, "same parameters, new strategy, because the salt moved");
        (, uint256 out) = quoteRouter(desk.order(), p, ONE_UBTC, true, true);
        assertGt(out, 0, "and it quotes");
    }

    // ---- ownership ----

    function test_onlyOwner_holdsTheFourCalls() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = openDesk(alice, "ramon", p, START_BASE, START_QUOTE);

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(DeskAccount.OnlyOwner.selector, bob));
        desk.close();
        vm.expectRevert(abi.encodeWithSelector(DeskAccount.OnlyOwner.selector, bob));
        desk.reopen(p, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(DeskAccount.OnlyOwner.selector, bob));
        desk.withdraw(address(ubtc), 1);
        vm.expectRevert(abi.encodeWithSelector(DeskAccount.OnlyOwner.selector, bob));
        desk.armHedge(true, 1);
        vm.stopPrank();

        vm.expectRevert(DeskAccount.AlreadyInitialized.selector);
        vm.prank(address(factory));
        desk.initialize(bob, "steal", p, 0, 0);
    }

    /// @dev Withdrawing under an open strategy is allowed and leaves the strategy committing more
    ///      than the account holds. Aqua does not check; the settlement transfer does.
    function test_withdraw_canLeaveTheDeskUnbacked() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = openDesk(alice, "ramon", p, START_BASE, START_QUOTE);
        ISwapVM.Order memory o = desk.order();
        fundTaker(o, p, ONE_UBTC, true, true);

        vm.prank(alice);
        desk.withdraw(address(usdt0), START_QUOTE);
        assertEq(usdt0.balanceOf(alice), START_QUOTE);

        vm.expectRevert();
        swapOnly(o, p, ONE_UBTC, true, true);
    }

    // ---- the hedge switch ----

    function test_armHedge_isOwnerState() public {
        DeskAccount desk = openDesk(alice, "ramon", btcParams(), START_BASE, START_QUOTE);
        assertFalse(desk.hedgeArmed(), "a desk opens disarmed");

        vm.prank(alice);
        desk.armHedge(true, 5_000e6);
        assertTrue(desk.hedgeArmed());
        assertEq(desk.hedgeMaxNotional(), 5_000e6);

        vm.prank(alice);
        desk.armHedge(false, 0);
        assertFalse(desk.hedgeArmed());
    }

    function test_onFill_onlyHooks() public {
        DeskAccount desk = openDesk(alice, "ramon", btcParams(), START_BASE, START_QUOTE);
        vm.expectRevert(abi.encodeWithSelector(DeskAccount.OnlyHooks.selector, address(this)));
        desk.onFill(bytes32(0), address(ubtc), address(usdt0), ONE_UBTC, 1, quietBook(), Side.Bid);
    }

    function test_onFill_disarmed_saysSo() public {
        DeskAccount desk = openDesk(alice, "ramon", btcParams(), START_BASE, START_QUOTE);

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeSkipped(ORDER, DeskAccount.SkipReason.Disarmed);
        vm.prank(address(hooks));
        desk.onFill(ORDER, address(ubtc), address(usdt0), ONE_UBTC, 1, quietBook(), Side.Bid);
    }

    /// @dev A quiet fill is inventory the desk wanted, not exposure it was forced into. Only the
    ///      absorbing side is hedged.
    function test_onFill_quietFill_isNotHedged() public {
        DeskAccount desk = armed(5_000e6);

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeSkipped(ORDER, DeskAccount.SkipReason.NotStressSide);
        vm.prank(address(hooks));
        desk.onFill(ORDER, address(ubtc), address(usdt0), ONE_UBTC, 1, quietBook(), Side.None);
    }

    /// @dev Bought base under a bid lean: the desk is long spot, so the perp leg sells. Notional is
    ///      the absorbed size at mark, in quote units, through the desk's own price scale.
    function test_onFill_absorbedBid_sellsThePerp() public {
        DeskAccount desk = armed(500_000e6);
        uint256 expected = ONE_UBTC * uint256(QUIET_MARK) / 1000;

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeIntent(ORDER, BTC, false, ONE_UBTC, expected, QUIET_MARK);
        vm.prank(address(hooks));
        desk.onFill(ORDER, address(ubtc), address(usdt0), ONE_UBTC, expected, quietBook(), Side.Bid);
    }

    /// @dev The mirror. Sold base under an ask lean: short spot, so the perp leg buys.
    function test_onFill_absorbedAsk_buysThePerp() public {
        DeskAccount desk = armed(500_000e6);
        uint256 notional = ONE_UBTC * uint256(QUIET_MARK) / 1000;

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeIntent(ORDER, BTC, true, ONE_UBTC, notional, QUIET_MARK);
        vm.prank(address(hooks));
        desk.onFill(ORDER, address(usdt0), address(ubtc), notional, ONE_UBTC, quietBook(), Side.Ask);
    }

    /// @dev The ceiling caps the size, it does not cancel the hedge. Half cover beats none, and the
    ///      ceiling is the number the owner signed for on the device.
    function test_onFill_capsAtMaxNotional() public {
        uint256 full = ONE_UBTC * uint256(QUIET_MARK) / 1000;
        DeskAccount desk = armed(uint64(full / 4));

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeIntent(ORDER, BTC, false, ONE_UBTC / 4, full / 4, QUIET_MARK);
        vm.prank(address(hooks));
        desk.onFill(ORDER, address(ubtc), address(usdt0), ONE_UBTC, full, quietBook(), Side.Bid);
    }

    /// @dev The book the hook hands over is zeros when the reader could not be reached — the hook
    ///      emits the fill anyway rather than unwinding it. A hedge sized off a mark of zero is not
    ///      a small hedge, it is a division by zero, so the account says so and does nothing.
    function test_onFill_unreadableBook_isNotHedged() public {
        DeskAccount desk = armed(5_000e6);

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeSkipped(ORDER, DeskAccount.SkipReason.NoNotional);
        vm.prank(address(hooks));
        desk.onFill(ORDER, address(ubtc), address(usdt0), ONE_UBTC, 1, Book(0, 0, 0, 0), Side.Bid);
    }

    /// @dev End to end, through 1inch's router: a taker sells into a dislocated book, the desk is
    ///      the absorbing side, and the cover decision comes out of the taker's own transaction --
    ///      same block, no keeper, nobody watching. This is the shape the CoreWriter leg drops into.
    function test_onFill_firesInsideTheTakersSwap() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = openDesk(alice, "ramon", p, START_BASE, START_QUOTE);
        vm.prank(alice);
        desk.armHedge(true, 500_000e6);

        // mark 782 000 against oracle 795 790 is 173 bps below: forced selling, and the desk leans
        // its bid inside the spread to take the flow.
        setBook(780_000, 790_000, 782_000, QUIET_ORACLE);
        ISwapVM.Order memory o = desk.order();
        (, uint256 expectedOut) = quoteRouter(o, p, ONE_UBTC, true, true);
        fundTaker(o, p, ONE_UBTC, true, true);

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeIntent(swapVM.hash(o), BTC, false, ONE_UBTC, ONE_UBTC * 782_000 / 1000, 782_000);
        swapOnly(o, p, ONE_UBTC, true, true);

        assertEq(ubtc.balanceOf(address(desk)), START_BASE + ONE_UBTC, "the desk absorbed the base");
        assertEq(usdt0.balanceOf(address(taker)), expectedOut, "and paid for it");
    }

    /// @dev Disarmed is the default, and it stays a decision the fill records rather than a silence.
    function test_onFill_disarmedDeskStillFills() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = openDesk(alice, "ramon", p, START_BASE, START_QUOTE);
        setBook(780_000, 790_000, 782_000, QUIET_ORACLE);

        ISwapVM.Order memory o = desk.order();
        fundTaker(o, p, ONE_UBTC, true, true);

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeSkipped(swapVM.hash(o), DeskAccount.SkipReason.Disarmed);
        swapOnly(o, p, ONE_UBTC, true, true);

        assertEq(ubtc.balanceOf(address(desk)), START_BASE + ONE_UBTC, "the fill is the fill either way");
    }

    // ---- helpers ----

    bytes32 internal constant ORDER = keccak256("fill");

    function armed(uint64 maxNotional) internal returns (DeskAccount desk) {
        desk = openDesk(alice, "ramon", btcParams(), START_BASE, START_QUOTE);
        vm.prank(alice);
        desk.armHedge(true, maxNotional);
    }

    function quietBook() internal pure returns (Book memory) {
        return Book({ bid: QUIET_BID, ask: QUIET_ASK, mark: QUIET_MARK, oracle: QUIET_ORACLE });
    }
}
