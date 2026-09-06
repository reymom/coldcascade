// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { Vm } from "forge-std/Vm.sol";

import { DeskTest } from "./base/DeskTest.sol";
import { CoreWriterMock } from "./mocks/CoreWriterMock.sol";
import { DeskAccount } from "../src/DeskAccount.sol";
import { DeskFactory } from "../src/DeskFactory.sol";
import { DeskParams } from "../src/libs/DeskParams.sol";

/// @notice The desk is a contract the maker owns, not a vault and not an EOA. These are the four
///         claims that makes: it can ship, a taker can pull from it, its owner can close it in one
///         call and get everything back, and a parameter change is a dock and a fresh ship.
contract DeskAccountTest is DeskTest {
    uint256 internal constant ONE_UBTC = 1e8;
    uint256 internal constant START_BASE = 10e8;
    uint256 internal constant START_QUOTE = 900_000e6;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal keeper = address(0xCAFE);

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

    /// @dev The implementation is not a desk and cannot become one: its own constructor took the
    ///      owner slot. A clone delegates into that code with blank storage of its own, so the same
    ///      slot is empty there and `initialize` works exactly once.
    function test_open_implementationCannotBeSeized() public {
        DeskAccount implementation = DeskAccount(factory.IMPLEMENTATION());
        assertEq(implementation.owner(), address(implementation), "the implementation owns itself");

        vm.expectRevert(DeskAccount.AlreadyInitialized.selector);
        vm.prank(bob);
        implementation.initialize(bob, "steal", btcParams(), 0, 0);
    }

    /// @dev And a clone that is already a desk cannot be re-initialized into somebody else's.
    function test_open_aDeskCannotBeReinitialized() public {
        DeskAccount desk = openDesk(alice, "ramon", btcParams(), START_BASE, START_QUOTE);
        vm.expectRevert(DeskAccount.AlreadyInitialized.selector);
        vm.prank(bob);
        desk.initialize(bob, "steal", btcParams(), 0, 0);
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
        desk.armHedge(true, 1, bob, HEDGE_SLIP_BPS);
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

    // ---- cover: the desk's own transaction ----

    function test_armHedge_isOwnerState() public {
        DeskAccount desk = openDesk(alice, "ramon", btcParams(), START_BASE, START_QUOTE);
        assertFalse(desk.hedgeArmed(), "a desk opens disarmed");

        vm.prank(alice);
        desk.armHedge(true, 5_000e6, keeper, HEDGE_SLIP_BPS);
        assertTrue(desk.hedgeArmed());
        assertEq(desk.hedgeMaxNotional(), 5_000e6);
        assertEq(desk.hedgeOperator(), keeper);
        assertEq(desk.hedgeMaxSlippageBps(), HEDGE_SLIP_BPS);

        vm.prank(alice);
        desk.armHedge(false, 0, address(0), 0);
        assertFalse(desk.hedgeArmed());
        assertEq(desk.hedgeOperator(), address(0));
    }

    /// @dev The operator fires within the ceiling; nobody else fires at all. The operator can move
    ///      no funds — every call that can is owner-only, and this one transfers nothing.
    function test_cover_onlyOwnerOrOperator() public {
        DeskAccount desk = armed(500_000e6);

        vm.expectRevert(abi.encodeWithSelector(DeskAccount.OnlyCoverCaller.selector, bob));
        vm.prank(bob);
        desk.cover();

        vm.prank(keeper);
        desk.cover();
        vm.prank(alice);
        desk.cover();
    }

    function test_cover_disarmedReverts() public {
        DeskAccount desk = openDesk(alice, "ramon", btcParams(), START_BASE, START_QUOTE);
        vm.expectRevert(DeskAccount.HedgeDisarmed.selector);
        vm.prank(alice);
        desk.cover();
    }

    /// @dev A desk opens square: what it was funded with is inventory its owner chose.
    function test_cover_aFreshDeskIsFlat() public {
        DeskAccount desk = armed(500_000e6);
        assertEq(desk.coveredBase(), START_BASE, "the opening balance is the square mark");

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeSkipped(1, DeskAccount.SkipReason.Flat);
        vm.prank(keeper);
        (bool covered,,) = desk.cover();
        assertFalse(covered);
    }

    /// @dev The move, end to end: a taker absorbs into the desk, the swap settles with the hook
    ///      emitting nothing but `Fill`, and cover happens afterwards in a transaction the desk
    ///      pays for. The two are not in the same block by construction and do not need to be.
    function test_cover_afterAFill_isASeparateTransaction() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = armed(500_000e6);
        setBook(780_000, 790_000, 782_000, QUIET_ORACLE);

        swapRouter(desk.order(), p, ONE_UBTC, true, true);
        assertEq(ubtc.balanceOf(address(desk)), START_BASE + ONE_UBTC, "the desk absorbed the base");

        uint256 expected = ONE_UBTC * 782_000 / 1000;
        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeIntent(1, BTC, false, ONE_UBTC, expected, 782_000);
        vm.prank(keeper);
        (bool covered, uint256 baseAmount, uint256 notional) = desk.cover();

        assertTrue(covered);
        assertEq(baseAmount, ONE_UBTC);
        assertEq(notional, expected);
        assertEq(desk.coveredBase(), START_BASE + ONE_UBTC, "and the desk is square again");
    }

    /// @dev Long base sells the perp. No sign is hard-coded anywhere else.
    function test_cover_longSellsThePerp() public {
        DeskAccount desk = armed(500_000e6);
        ubtc.mint(address(desk), ONE_UBTC);

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeIntent(1, BTC, false, ONE_UBTC, ONE_UBTC * QUIET_MARK / 1000, QUIET_MARK);
        vm.prank(keeper);
        desk.cover();
    }

    /// @dev The mirror: a desk that has shed base is short spot and the perp leg buys.
    function test_cover_shortBuysThePerp() public {
        DeskAccount desk = armed(500_000e6);
        vm.prank(address(desk));
        ubtc.transfer(bob, ONE_UBTC);

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeIntent(1, BTC, true, ONE_UBTC, ONE_UBTC * QUIET_MARK / 1000, QUIET_MARK);
        vm.prank(keeper);
        desk.cover();
    }

    /// @dev The delta nets. A desk that bought and sold back covers once, where a per-fill hedge
    ///      would have sent two orders and paid two spreads for a position it no longer has.
    function test_cover_netsRoundTrips() public {
        DeskAccount desk = armed(500_000e6);
        ubtc.mint(address(desk), ONE_UBTC);
        vm.prank(address(desk));
        ubtc.transfer(bob, ONE_UBTC);

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeSkipped(1, DeskAccount.SkipReason.Flat);
        vm.prank(keeper);
        (bool covered,,) = desk.cover();
        assertFalse(covered, "bought and sold back is not a position");
    }

    /// @dev The ceiling caps a call, it does not drop the remainder: the next call picks it up.
    ///      That is the difference between a ceiling and a switch.
    function test_cover_capLeavesTheRemainderForNextTime() public {
        uint256 full = ONE_UBTC * uint256(QUIET_MARK) / 1000;
        DeskAccount desk = armed(uint64(full / 4));
        ubtc.mint(address(desk), ONE_UBTC);

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeIntent(1, BTC, false, ONE_UBTC / 4, full / 4, QUIET_MARK);
        vm.prank(keeper);
        desk.cover();
        assertEq(desk.coveredBase(), START_BASE + ONE_UBTC / 4, "only what was covered is marked");

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeIntent(2, BTC, false, ONE_UBTC / 4, full / 4, QUIET_MARK);
        vm.prank(keeper);
        desk.cover();
    }

    /// @dev In its own transaction there is no fill to protect, so a book that cannot be read is an
    ///      error the caller sees rather than a silence it has to notice.
    function test_cover_unreadableBookReverts() public {
        DeskAccount desk = armed(500_000e6);
        ubtc.mint(address(desk), ONE_UBTC);
        setBook(0, 0, 0, 0);

        vm.expectRevert();
        vm.prank(keeper);
        desk.cover();
    }

    /// @dev `coveredBase` is the balance level at which the desk is square, so taking base out
    ///      lowers the level by the same amount and leaves the uncovered delta where it was.
    function test_cover_withdrawDoesNotReadAsAShort() public {
        DeskAccount desk = armed(500_000e6);
        ubtc.mint(address(desk), ONE_UBTC);

        vm.prank(alice);
        desk.withdraw(address(ubtc), 2e8);
        assertEq(desk.coveredBase(), START_BASE - 2e8, "the square level dropped by what left");

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeIntent(1, BTC, false, ONE_UBTC, ONE_UBTC * QUIET_MARK / 1000, QUIET_MARK);
        vm.prank(keeper);
        desk.cover();
    }

    /// @dev A parameter change is not a position change.
    function test_cover_reopenKeepsTheMark() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = armed(500_000e6);
        ubtc.mint(address(desk), ONE_UBTC);

        DeskParams memory wider = p;
        wider.quietBps = 60;
        vm.prank(alice);
        desk.reopen(wider, START_BASE, START_QUOTE);

        assertEq(desk.coveredBase(), START_BASE, "reopening did not silently mark the desk square");
        (bool wouldCover,, uint256 baseAmount,) = desk.coverPreview();
        assertTrue(wouldCover);
        assertEq(baseAmount, ONE_UBTC, "the uncovered fill survived the parameter change");
    }

    function test_cover_closeLeavesNothingToCover() public {
        DeskAccount desk = armed(500_000e6);
        ubtc.mint(address(desk), ONE_UBTC);

        vm.prank(alice);
        desk.close();
        assertEq(desk.coveredBase(), 0);
        assertEq(ubtc.balanceOf(address(desk)), 0);

        (bool wouldCover,,,) = desk.coverPreview();
        assertFalse(wouldCover, "nothing held, nothing to cover");
    }

    /// @dev What the keeper's queue and the console's hedge row read before anyone signs.
    function test_coverPreview_matchesWhatCoverDoes() public {
        DeskAccount desk = armed(500_000e6);
        ubtc.mint(address(desk), ONE_UBTC);

        (bool wouldCover, bool isBuy, uint256 previewBase, uint256 previewNotional) = desk.coverPreview();
        vm.prank(keeper);
        (bool covered, uint256 baseAmount, uint256 notional) = desk.cover();

        assertEq(wouldCover, covered);
        assertFalse(isBuy, "long base sells");
        assertEq(previewBase, baseAmount);
        assertEq(previewNotional, notional);
    }

    /// @dev What cover costs, in the desk's own transaction, paid by the desk. 42 138 gas before
    ///      the order leg, measured 2026-09-05; 66 725 with it, measured here.
    ///
    ///      The leg was `[UNVERIFIED]` against chain 999 until the probe ran on 2026-09-06. Two
    ///      real transactions from a contract that had never signed anything: a `usdClassTransfer`
    ///      cost 53 959 gas and a limit order 57 255, both including the 21 000 of an EVM
    ///      transaction and the contract's own dispatch. So HyperCore's *"~47 000 with 25 000
    ///      burned"* is a ceiling and not an estimate — the action itself lands nearer 32 000.
    ///
    ///      The number here is higher than either because the reads come first: `0x080a` for
    ///      `szDecimals` and three more for the book. All of it is charged to the desk. **A taker
    ///      pays none of it, which is the claim this test exists to keep true.**
    function test_cover_costsTheDeskNotTheTaker() public {
        DeskAccount desk = armed(500_000e6);
        ubtc.mint(address(desk), ONE_UBTC);

        vm.prank(keeper);
        uint256 before = gasleft();
        desk.cover();
        uint256 spent = before - gasleft();

        emit log_named_uint("cover gas, paid by the desk", spent);
        assertLt(spent, 100_000, "one transaction, and no taker is in it");
    }

    // ---- the order that comes out of a cover ----

    /// @dev The payload, whole. Built independently by the mock from the exchange's own layout and
    ///      compared byte for byte, so this fails if the header, the field order, the scale or the
    ///      time-in-force move — not just if a number is off.
    ///
    ///      UBTC has 8 decimals and BTC's `sz` field is `1e8 *` human, so one UBTC is `sz` 1e8.
    ///      The desk is long base and sells, so the limit sits `HEDGE_SLIP_BPS` under the bid:
    ///      795 510 * 0.997 = 793 123.47, truncated toward the aggressive side at five significant
    ///      figures gives 793 120 raw, and `* 10 ** (2 + szDecimals)` puts it in the 1e8 scale.
    function test_cover_sendsTheOrderItDecided() public {
        DeskAccount desk = armed(500_000e6);
        ubtc.mint(address(desk), ONE_UBTC);

        uint64 limitPx = uint64(uint256(793_120) * 10 ** (2 + BTC_SZ_DECIMALS));

        vm.expectEmit(address(CORE_WRITER));
        emit CoreWriterMock.RawAction(writer().limitOrder(BTC, false, limitPx, uint64(ONE_UBTC), 3, 1));
        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeSent(1, BTC, false, limitPx, uint64(ONE_UBTC));

        vm.prank(keeper);
        desk.cover();
    }

    /// @dev The cloid is the cover id, which is the whole reason `coverCount` is a counter: an
    ///      order sitting in HyperCore's book can be matched back to the decision that made it.
    function test_cover_cloidIsTheCoverId() public {
        DeskAccount desk = armed(500_000e6);

        ubtc.mint(address(desk), ONE_UBTC);
        vm.prank(keeper);
        desk.cover();
        assertEq(desk.coverCount(), 1);

        ubtc.mint(address(desk), ONE_UBTC);
        vm.expectEmit(address(CORE_WRITER));
        emit CoreWriterMock.RawAction(
            writer().limitOrder(BTC, false, uint64(uint256(793_120) * 10 ** (2 + BTC_SZ_DECIMALS)), uint64(ONE_UBTC), 3, 2)
        );
        vm.prank(keeper);
        desk.cover();
        assertEq(desk.coverCount(), 2, "and the second order carries the second id");
    }

    /// @dev *"Sizes are rounded to the szDecimals of that asset."* BTC's grid is 1e-5, which on a
    ///      1e8 field is a lot of 1 000 — so a sub-lot exposure has no order that can express it.
    ///      The desk must not send one and must not mark itself covered: HyperCore would drop the
    ///      order and return a successful receipt, and the position would be uncovered and silent.
    function test_cover_belowOneLot_isNotSentAndNotMarked() public {
        DeskAccount desk = armed(500_000e6);
        ubtc.mint(address(desk), 999);

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeSkipped(1, DeskAccount.SkipReason.BelowLot);
        vm.prank(keeper);
        (bool covered,,) = desk.cover();

        assertFalse(covered);
        assertEq(desk.coveredBase(), START_BASE, "the square mark did not move");
    }

    /// @dev The remainder under the lot survives to be covered later, rather than being rounded
    ///      into an order the desk cannot place or silently marked as done. 123 456 of UBTC is
    ///      1.23456e-3 BTC, about $98 at the quiet mark, so the minimum is not what bites here.
    function test_cover_floorsToTheLotAndKeepsTheRemainder() public {
        DeskAccount desk = armed(500_000e6);
        ubtc.mint(address(desk), 123_456);

        vm.prank(keeper);
        (bool covered, uint256 baseAmount,) = desk.cover();

        assertTrue(covered);
        assertEq(baseAmount, 123_000, "floored onto the grid, never rounded up");
        assertEq(desk.coveredBase(), START_BASE + 123_000, "and only what was sent is marked");

        (,, uint256 stillOpen,) = desk.coverPreview();
        assertEq(stillOpen, 0, "456 is under a lot, so it stays uncovered and unclaimed");
    }

    /// @dev *"Order must have minimum value of $10."* Checked in the exchange's own terms, so it
    ///      holds whatever the quote token is. 13 000 of UBTC is 1.3e-4 BTC — about $10.34 at the
    ///      quiet mark, just over — and 12 000 is $9.55, just under.
    function test_cover_belowTenDollars_isNotSent() public {
        DeskAccount desk = armed(500_000e6);
        ubtc.mint(address(desk), 12_000);

        vm.expectEmit(true, true, true, true, address(desk));
        emit DeskAccount.HedgeSkipped(1, DeskAccount.SkipReason.BelowExchangeMinimum);
        vm.prank(keeper);
        (bool covered,,) = desk.cover();

        assertFalse(covered);
        assertEq(desk.coveredBase(), START_BASE, "and nothing was marked covered");

        ubtc.mint(address(desk), 1_000);
        vm.prank(keeper);
        (covered,,) = desk.cover();
        assertTrue(covered, "one lot more clears the minimum");
    }

    /// @dev A short desk lifts the ask, and the limit rounds the other way. 795 520 * 1.003 =
    ///      797 906.56, and rounding up at five significant figures gives 797 910.
    function test_cover_shortLiftsTheAsk() public {
        DeskAccount desk = armed(500_000e6);
        vm.prank(alice);
        desk.withdraw(address(ubtc), 0);
        vm.prank(address(desk));
        ubtc.transfer(alice, ONE_UBTC);

        uint64 limitPx = uint64(uint256(797_910) * 10 ** (2 + BTC_SZ_DECIMALS));
        vm.expectEmit(address(CORE_WRITER));
        emit CoreWriterMock.RawAction(writer().limitOrder(BTC, true, limitPx, uint64(ONE_UBTC), 3, 1));
        vm.prank(keeper);
        desk.cover();
    }

    /// @dev *"Prices can have up to 5 significant figures."* A limit that carries more is rejected
    ///      by the exchange and the EVM transaction still succeeds, so the shape is a correctness
    ///      property and not a nicety. The bound is swept because the arithmetic that produces it
    ///      is a multiply and a truncate, and those disagree at the edges.
    function testFuzz_cover_limitPriceIsAlwaysAcceptable(uint16 slipBps, uint64 bid) public {
        slipBps = uint16(bound(slipBps, 0, 9_999));
        bid = uint64(bound(bid, 1_000, 100_000_000));
        setBook(bid, bid + 10, bid, bid);

        DeskAccount desk = openDesk(alice, "ramon", btcParams(), START_BASE, START_QUOTE);
        vm.prank(alice);
        desk.armHedge(true, type(uint64).max, keeper, slipBps);
        ubtc.mint(address(desk), ONE_UBTC);

        vm.recordLogs();
        vm.prank(keeper);
        (bool covered,,) = desk.cover();
        if (!covered) return;

        uint64 limitPx = _sentLimitPx();
        uint256 unit = 10 ** (2 + uint256(BTC_SZ_DECIMALS));
        assertEq(limitPx % unit, 0, "no more than 6 - szDecimals decimal places");

        uint256 head = limitPx / unit;
        uint256 digits;
        for (uint256 v = head; v != 0; v /= 10) digits++;
        uint256 significant = head;
        while (digits > 5) {
            assertEq(significant % 10, 0, "the digits past the fifth are zero");
            significant /= 10;
            digits--;
        }
    }

    /// @dev The bound is an authorisation, so it has to be one the contract can enforce. 100% and
    ///      above would underflow a sell limit into an enormous number.
    function test_armHedge_rejectsAnUnenforceableBound() public {
        DeskAccount desk = openDesk(alice, "ramon", btcParams(), START_BASE, START_QUOTE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeskAccount.SlippageOutOfRange.selector, uint16(10_000)));
        desk.armHedge(true, 1, keeper, 10_000);
    }

    /// @dev **The implementation has to fit in one HyperEVM small block.** Blocks cap at 3 000 000
    ///      gas and code deposit is 200 gas a byte, so a contract's runtime size is a deployment
    ///      constraint before it is a taker cost — this is why `optimizer_runs` is 200 and not
    ///      1 000 000, and the reasoning is in foundry.toml and results/999_deploy_budget.md.
    ///
    ///      The order leg cost 1 293 bytes and leaves **44 367 gas of headroom**, about 220 bytes
    ///      of runtime code. It was 654 gas — three bytes — until `HyperCore.szDecimals` stopped
    ///      decoding `PerpAssetInfo` through `abi.decode` and started reading the field at its
    ///      offset; the dynamic ABI decoder alone was 43 713 gas of code deposit. When this does
    ///      run out, the way through is a deployed library for the order arithmetic, not a higher
    ///      bound: the bound is the chain's.
    function test_implementation_fitsOneSmallBlock() public {
        uint256 before = gasleft();
        new DeskAccount(aqua, address(swapVM), address(coreQuote), address(hooks));
        uint256 spent = before - gasleft();

        emit log_named_uint("DeskAccount implementation deploy gas", spent);
        emit log_named_uint("headroom under a 3M small block", 3_000_000 - (spent + 21_000));
        assertLt(spent + 21_000, 3_000_000, "HyperEVM small blocks cap at 3 000 000 gas");
    }

    // ---- helpers ----

    /// @dev The `limitPx` out of the last recorded CoreWriter action.
    function _sentLimitPx() internal returns (uint64 limitPx) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].emitter != CORE_WRITER) continue;
            bytes memory data = abi.decode(logs[i - 1].data, (bytes));
            bytes memory payload = new bytes(data.length - 4);
            for (uint256 j = 4; j < data.length; j++) {
                payload[j - 4] = data[j];
            }
            (,, limitPx,,,,) = abi.decode(payload, (uint32, bool, uint64, uint64, bool, uint8, uint128));
            return limitPx;
        }
        revert("no action");
    }


    function armed(uint64 maxNotional) internal returns (DeskAccount desk) {
        desk = openDesk(alice, "ramon", btcParams(), START_BASE, START_QUOTE);
        vm.prank(alice);
        desk.armHedge(true, maxNotional, keeper, HEDGE_SLIP_BPS);
    }

}
