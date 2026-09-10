// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { DeskTest } from "./base/DeskTest.sol";
import { PegQuote } from "../src/PegQuote.sol";
import { DeskParams } from "../src/libs/DeskParams.sol";
import { DeskPrograms } from "../src/libs/DeskPrograms.sol";

/// @title PegQuoteTest
/// @notice The comparator, checked for the two things that would make it a straw man in either
///         direction: that it really is centred on the oracle when it refreshes, and that it
///         really does stand still when it does not.
///
///         A comparator that quietly tracked the book would understate what an oracle-pegged
///         maker pays and make the desk look worse than it is. One that quietly stopped quoting
///         would overstate it and make the desk look better. Both are silent — they produce a
///         line on a chart either way — so both are asserted here rather than assumed from the
///         source.
///
/// @dev `Inarbitrable.t.sol` is the same round trip against the desk, and the two files are meant
///      to be read together: there it never pays, here it pays as soon as the oracle is stale by
///      more than the band. That contrast is the whole of the argument, and it is one arithmetic
///      expression evaluated against two makers.
contract PegQuoteTest is DeskTest {
    uint256 internal constant START_BASE = 40e8;
    /// @dev A thousandth of a UBTC. Small enough against 40 that curve slippage is under a basis
    ///      point, so an assertion about the *price* is not really an assertion about the depth.
    uint256 internal constant CLIP = 1e5;
    /// @dev What that clip costs itself on the curve: `CLIP / (START_BASE + CLIP)` is 25 parts per
    ///      million, which at these prices is 20 raw units. An assertion about where the peg sits
    ///      has to leave room for it, or it is an assertion about the depth instead.
    uint256 internal constant IMPACT = 25;

    bytes32 internal constant KEY = keccak256("pegged");
    bytes32 internal constant SALT = keccak256("pegged-salt");

    DeskParams internal p;
    ISwapVM.Order internal pegged;
    bytes32 internal peggedHash;

    function setUp() public virtual override {
        super.setUp();
        p = btcParams();
        pegged = peggedOrder(p, KEY, SALT);
        // Shipped with the quote leg the peg itself implies, so `offset` opens at zero and any
        // difference below is the instruction rather than the inventory it started with.
        peggedHash = shipFunded(pegged, p, START_BASE, atOracle(START_BASE, QUIET_ORACLE));
        armPeg(KEY, peggedHash, p, 0, 60);
    }

    // ---- it is where it says it is ----

    function test_arm_centresTheCurveOnTheOracle() public view {
        assertApproxEqAbs(bidPxOf(pegged), QUIET_ORACLE, IMPACT, "the bid opens on the oracle");
        assertApproxEqAbs(askPxOf(pegged), QUIET_ORACLE, IMPACT, "and so does the ask");
    }

    function test_arm_recordsThePriceAndTheMoment() public view {
        PegQuote.Peg memory peg = pegQuote.peg(KEY);
        assertEq(peg.px, QUIET_ORACLE);
        assertEq(peg.at, uint64(block.timestamp));
        assertEq(peg.offset, 0, "the opening inventory is already on the peg");
    }

    // ---- and it stays there ----

    /// @notice The property the comparator exists for. Move the oracle a full percent and, until
    ///         somebody sends a refresh, this maker is still quoting the old number.
    function test_betweenRefreshes_itDoesNotFollowTheOracle() public {
        uint256 before = bidPxOf(pegged);
        setBook(787_000, 787_010, 787_000, 787_000); // a percent below where it was armed
        assertEq(bidPxOf(pegged), before, "the price did not move, because nothing moved it");
    }

    function test_refresh_holdsInsideTheHeartbeat() public {
        setBook(787_000, 787_010, 787_000, 787_000);
        vm.warp(block.timestamp + 59);
        assertFalse(pegQuote.refresh(KEY), "59 seconds is not 60");
        assertApproxEqAbs(bidPxOf(pegged), QUIET_ORACLE, IMPACT);
    }

    function test_refresh_movesItOnTheHeartbeat() public {
        setBook(787_000, 787_010, 787_000, 787_000);
        vm.warp(block.timestamp + 60);
        assertTrue(pegQuote.refresh(KEY));
        assertApproxEqAbs(bidPxOf(pegged), 787_000, IMPACT, "and now it is on the new one");
    }

    /// @dev The other dial. A deviation threshold is what a pushed feed is actually configured
    ///      with, and zero has to mean *off* rather than *always*: `>= 0` is true of every move,
    ///      so a maker with a zero threshold and an hour of heartbeat would be repriced by the
    ///      last decimal of the oracle instead of standing still for an hour.
    function test_refresh_movesItOnTheDeviation() public {
        bytes32 key = keccak256("deviation");
        ISwapVM.Order memory o = peggedOrder(p, key, keccak256("deviation-salt"));
        bytes32 h = shipFunded(o, p, START_BASE, atOracle(START_BASE, QUIET_ORACLE));
        armPeg(key, h, p, 25, 1 days);

        setBook(795_000, 795_010, 795_000, 795_000); // 10 bps under the peg
        vm.warp(block.timestamp + 1);
        assertFalse(pegQuote.refresh(key), "ten basis points does not clear twenty-five");

        setBook(793_800, 793_810, 793_800, 793_800); // 25 bps under it
        assertTrue(pegQuote.refresh(key), "twenty-five does");
    }

    // ---- it is still an AMM in between ----

    /// @notice Standing still is not the same as quoting one price forever. Between refreshes the
    ///         curve walks along itself exactly as the plain control does, because the real
    ///         balances move with every fill and only the offset is frozen. A comparator that
    ///         reset itself after every trade would be one a searcher could drain at a fixed
    ///         price, and the number it produced would be a fact about this file.
    function test_aFillMovesIt_theWayACurveMoves() public {
        uint256 before = bidPxOf(pegged);
        swapRouter(pegged, p, 2e8, true, true); // sell it two whole UBTC
        assertLt(bidPxOf(pegged), before, "it just bought base, so it bids lower for the next lot");
    }

    // ---- what it costs, and why the file exists ----

    /// @notice The round trip `Inarbitrable.t.sol` runs against the desk, run against this one.
    ///         There it comes back short by the band, in every book, on both sides. Here, as soon
    ///         as the oracle it is pegged to is a percent away from the book a searcher closes at,
    ///         the same trip comes back long — and the maker paid the difference.
    function test_aStalePeg_isArbitrageable() public {
        setBook(787_000, 787_010, 787_000, 787_000);   // the book fell; the peg did not

        (, uint256 got) = quoteRouter(pegged, p, CLIP, true, true);  // sell base at the stale bid
        uint256 back = got * p.pxDen / (uint256(787_010) * p.pxNum); // buy it back at L1's ask
        assertGt(back, CLIP, "the searcher ends with more base than they started with");
    }

    function test_aFreshPeg_isNotArbitrageableByMuch() public {
        setBook(787_000, 787_010, 787_000, 787_000);
        vm.warp(block.timestamp + 60);
        pegQuote.refresh(KEY);

        (, uint256 got) = quoteRouter(pegged, p, CLIP, true, true);
        uint256 back = got * p.pxDen / (uint256(787_010) * p.pxNum);
        assertLt(back, CLIP, "on a fresh peg the round trip is under water, like any spread");
    }

    // ---- the two ways to build it wrong ----

    /// @notice `Extruction(PegQuote) || XYCSwap` re-centres the curve. `XYCSwap || Extruction`
    ///         re-centres nothing: the arithmetic already happened, so the balances it writes are
    ///         read by no one and the maker quotes off its own reserves. That failure has no error
    ///         message — it draws the plain control a second time under a different name — so it
    ///         is pinned here rather than left to the comment in `DeskPrograms`.
    function test_theExtructionHasToComeFirst() public {
        bytes32 key = keccak256("backwards");
        bytes memory backwards = bytes.concat(
            DeskPrograms.instruction(17, ""),                                        // XYCSwap
            DeskPrograms.instruction(32, abi.encodePacked(address(pegQuote), key)),  // Extruction
            DeskPrograms.instruction(20, abi.encodePacked(keccak256("backwards-salt")))
        );
        ISwapVM.Order memory o = DeskPrograms.order(maker, address(0), backwards, p);

        // Ship it off the peg on purpose: reserves that imply 780 000 against an oracle at 795 790.
        bytes32 h = shipFunded(o, p, START_BASE, atOracle(START_BASE, 780_000));
        armPeg(key, h, p, 0, 60);

        assertApproxEqAbs(bidPxOf(o), 780_000, IMPACT, "it quoted the reserves, not the peg");
    }

    /// @dev The revert is taken directly off the view router rather than through `quoteRouter`,
    ///      because `asView()` is itself an external call and would swallow the `expectRevert`.
    function test_anUnarmedKey_doesNotQuote() public {
        ISwapVM.Order memory o = peggedOrder(p, keccak256("never-armed"), keccak256("na"));
        shipFunded(o, p, START_BASE, atOracle(START_BASE, QUIET_ORACLE));

        ISwapVM view_ = swapVM.asView();
        bytes memory takerData = deskTakerData(address(taker), true, false);
        vm.expectRevert(abi.encodeWithSelector(PegQuote.NotArmed.selector, keccak256("never-armed")));
        view_.quote(o, p.base, p.quote, CLIP, takerData);
    }

    function test_armingTwice_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(PegQuote.AlreadyArmed.selector, KEY));
        armPeg(KEY, peggedHash, p, 0, 60);
    }

    function test_refreshingAnUnarmedKey_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(PegQuote.NotArmed.selector, bytes32(0)));
        pegQuote.refresh(bytes32(0));
    }

    // ---- helpers ----

    /// @dev The quote leg that puts a constant-product curve's marginal price on a raw L1 price.
    function atOracle(uint256 baseAmount, uint64 rawPx) internal view returns (uint256) {
        return baseAmount * uint256(rawPx) * p.pxNum / p.pxDen;
    }

    /// @dev What this maker pays for base, as a raw L1 price, off a clip small enough that the
    ///      curve's own impact is under a basis point.
    function bidPxOf(ISwapVM.Order memory o) internal view returns (uint256) {
        (, uint256 got) = quoteRouter(o, p, CLIP, true, true);
        return got * p.pxDen / (CLIP * p.pxNum);
    }

    /// @dev And what it charges for it.
    function askPxOf(ISwapVM.Order memory o) internal view returns (uint256) {
        (uint256 paid,) = quoteRouter(o, p, CLIP, false, false);
        return paid * p.pxDen / (CLIP * p.pxNum);
    }
}
