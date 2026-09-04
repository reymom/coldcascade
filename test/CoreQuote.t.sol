// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";

import { DeskTest } from "./base/DeskTest.sol";
import { CoreQuote } from "../src/CoreQuote.sol";
import { DeskParams, DeskParamsLib } from "../src/libs/DeskParams.sol";
import { Regime, Side } from "../src/libs/Regime.sol";

/// @notice The Saturday suite. Every claim in the README is one of these.
/// @dev The book comes through CorePrecompiles from HyperCoreMock etched at 0x0806/0x0807/0x080e,
///      so these exercise the reader the desk actually ships with. Books are raw HyperCore units.
contract CoreQuoteTest is DeskTest {
    uint256 internal constant NEXT_PC = 7;
    uint256 internal constant ONE_UBTC = 1e8;
    uint256 internal constant INVENTORY = 10e8;

    /// @dev One UBTC valued at the quiet L1 bid: 795 510 raw is $79 551.0, so 79 551 000 000 USDT0
    ///      units. `test_priceScale_btcOnUbtcUsdt0_is1Over1000` pins the scale this comes from.
    uint256 internal constant ONE_UBTC_AT_L1_BID = 79_551_000_000;

    /// @dev A dislocated, wide book: mark 13 790 raw below oracle is 173 bps, well past stressBps,
    ///      and the 10 000 raw spread leaves room for a 15 bps lean to land strictly inside it.
    ///      Both are what a real forced-selling minute looks like; the quiet 999 book is neither.
    uint64 internal constant WIDE_BID = 780_000;
    uint64 internal constant WIDE_ASK = 790_000;
    uint64 internal constant WIDE_MARK = 782_000;

    // ---- the quiet: the desk cannot be taken stale ----

    function test_quiet_bidSitsOutsideL1() public view {
        uint256 out = bidOut(btcParams(), ONE_UBTC, 0);
        assertLt(out, ONE_UBTC_AT_L1_BID, "the desk bid must be worse for the taker than L1's");
        assertEq(out, ONE_UBTC * QUIET_BID * (10_000 - QUIET_BPS) / 10_000_000, "quiet bid");
    }

    function test_quiet_askSitsOutsideL1() public view {
        uint256 atL1Ask = ONE_UBTC_AT_L1_BID * 1000 / QUIET_ASK;
        uint256 out = askOut(btcParams(), ONE_UBTC_AT_L1_BID, 0);
        assertLt(out, atL1Ask, "the desk must hand out less base than L1 would");
    }

    /// @dev In the quiet the desk is a bound, never an improvement: whatever the curve said, the
    ///      taker gets the worse of the two. That is what makes a stale quote unprofitable to take.
    function test_quiet_neverBetterThanCurve() public view {
        uint256 stingy = 70_000_000_000;
        assertEq(bidOut(btcParams(), ONE_UBTC, stingy), stingy, "a stingy curve stands");

        uint256 generous = 79_500_000_000;
        uint256 out = bidOut(btcParams(), ONE_UBTC, generous);
        assertLt(out, generous, "a generous curve is cut back to the book");
    }

    function test_quiet_noCurve_quotesOffTheBook() public view {
        assertEq(bidOut(btcParams(), ONE_UBTC, 0), 79_391_898_000, "pure book quote, no curve ahead");
    }

    // ---- stress: the absorbing side leans in, the other side keeps its bound ----

    function test_stressDown_bidLeansInsideSpread() public {
        setBook(WIDE_BID, WIDE_ASK, WIDE_MARK, QUIET_ORACLE);
        DeskParams memory p = btcParams();

        assertEq(uint8(coreQuote.regime(p).lean), uint8(Side.Bid), "forced selling leans the bid");

        uint256 out = bidOut(p, ONE_UBTC, 0);
        assertGt(out, ONE_UBTC * WIDE_BID / 1000, "inside the spread, above L1's bid");
        assertLt(out, ONE_UBTC * WIDE_ASK / 1000, "and still below L1's ask");
    }

    function test_stressUp_askLeansInsideSpread() public {
        // The mirror: mark above oracle is forced buying, and the maker sells into it.
        setBook(790_000, 800_000, QUIET_MARK, 780_000);
        DeskParams memory p = btcParams();

        assertEq(uint8(coreQuote.regime(p).lean), uint8(Side.Ask), "forced buying leans the ask");

        uint256 quoteIn = ONE_UBTC_AT_L1_BID;
        uint256 out = askOut(p, quoteIn, 0);
        assertGt(out, quoteIn * 1000 / 800_000, "more base than L1's ask would give");
        assertLt(out, quoteIn * 1000 / 790_000, "but never more than L1's bid would");
    }

    /// @dev Only the absorbing side moves. The other one keeps sitting outside L1, which is what
    ///      stops the desk from being run over on the leg it did not choose.
    function test_stress_otherSideStaysBounded() public {
        setBook(WIDE_BID, WIDE_ASK, WIDE_MARK, QUIET_ORACLE);
        DeskParams memory p = btcParams();

        uint256 quoteIn = ONE_UBTC_AT_L1_BID;
        uint256 out = askOut(p, quoteIn, 0);
        assertLt(out, quoteIn * 1000 / WIDE_ASK, "the unleaning side is still outside L1's ask");
        assertEq(out, quoteIn * 10_000 * 1000 / (uint256(WIDE_ASK) * (10_000 + QUIET_BPS)), "quiet ask");
    }

    /// @dev The cap biting is the normal case on a tight book: a 15 bps lean on a 0.13 bps spread
    ///      wants 796 703 raw, which is through L1's own offer. The desk stops at the offer.
    function test_neverPaysAboveL1Ask() public {
        setBook(QUIET_BID, QUIET_ASK, 780_000, QUIET_ORACLE);
        DeskParams memory p = btcParams();
        assertEq(uint8(coreQuote.regime(p).lean), uint8(Side.Bid), "the tight book is still stressed");

        uint256 uncapped = ONE_UBTC * QUIET_BID * (10_000 + LEAN_BPS) / 10_000_000;
        uint256 atL1Ask = ONE_UBTC * QUIET_ASK / 1000;
        assertGt(uncapped, atL1Ask, "the fixture must actually push the lean through the ask");

        assertEq(bidOut(p, ONE_UBTC, 0), atL1Ask, "capped at L1's ask, not at the lean");
        assertEq(atL1Ask, 79_552_000_000, "one UBTC at the quiet L1 ask");
    }

    function test_neverSellsBelowL1Bid() public {
        // Same squeeze on the ask side: the lean wants 794 327 raw, which is under L1's own bid.
        setBook(QUIET_BID, QUIET_ASK, QUIET_MARK, 780_000);
        DeskParams memory p = btcParams();
        assertEq(uint8(coreQuote.regime(p).lean), uint8(Side.Ask), "stress up on a tight book");

        uint256 quoteIn = ONE_UBTC_AT_L1_BID;
        assertEq(askOut(p, quoteIn, 0), ONE_UBTC, "floored at L1's bid: exactly one UBTC");
    }

    function test_stressThreshold_isMakerParameter() public {
        setBook(WIDE_BID, WIDE_ASK, WIDE_MARK, QUIET_ORACLE);

        DeskParams memory tight = btcParams();
        DeskParams memory loose = btcParams();
        loose.stressBps = 500; // 173 bps of dislocation is not stress to this maker

        assertEq(uint8(coreQuote.regime(tight).lean), uint8(Side.Bid));
        assertEq(uint8(coreQuote.regime(loose).lean), uint8(Side.None));
        assertGt(bidOut(tight, ONE_UBTC, 0), bidOut(loose, ONE_UBTC, 0), "the sign is the maker's");
    }

    /// @dev The whole point, in two calls: same order, same params, the book moved underneath.
    ///      The router-level version on a fork of 999 is ARCHITECTURE §2.5 and is still skipped.
    function test_bookMoves_quoteMoves() public {
        DeskParams memory p = btcParams();
        uint256 quiet = bidOut(p, ONE_UBTC, 0);

        setBook(WIDE_BID, WIDE_ASK, WIDE_MARK, QUIET_ORACLE);
        uint256 stressed = bidOut(p, ONE_UBTC, 0);

        assertTrue(quiet != stressed, "the quote did not move with the book");
    }

    // ---- fail closed ----

    function test_emptyBbo_failsClosed() public {
        setBook(0, 0, QUIET_MARK, QUIET_ORACLE);
        vm.expectRevert(abi.encodeWithSelector(CoreQuote.EmptyBook.selector, BTC));
        this.callQuote(btcParams(), true, true, registers(ONE_UBTC, 0));

        // A reader that hands back zeros instead of reverting is caught by the quote itself.
        CoreQuote cached = new CoreQuote(reader);
        vm.expectRevert(abi.encodeWithSelector(CoreQuote.EmptyBook.selector, BTC));
        cached.extruction(true, NEXT_PC, query(true, true), registers(ONE_UBTC, 0), encoded(btcParams()), "");
    }

    function test_crossedBook_failsClosed() public {
        setBook(795_530, QUIET_ASK, QUIET_MARK, QUIET_ORACLE);
        vm.expectRevert(abi.encodeWithSelector(CoreQuote.CrossedBook.selector, uint64(795_530), QUIET_ASK));
        this.callQuote(btcParams(), true, true, registers(ONE_UBTC, 0));
    }

    function test_wrongPair_reverts() public {
        DeskParams memory p = btcParams();
        SwapQuery memory q = query(true, true);
        q.tokenOut = address(ubtc);
        vm.expectRevert(abi.encodeWithSelector(CoreQuote.WrongPair.selector, address(ubtc), address(ubtc)));
        coreQuote.extruction(true, NEXT_PC, q, registers(ONE_UBTC, 0), encoded(p), "");
    }

    /// @dev Buying base walks into maxBase; selling it walks into minBase. Neither is resized.
    function test_inventoryCap_reverts() public {
        DeskParams memory p = btcParams();
        p.maxBase = uint128(ONE_UBTC / 2);

        SwapRegisters memory regs = registers(ONE_UBTC, 0);
        regs.balanceIn = 0;
        vm.expectRevert(
            abi.encodeWithSelector(CoreQuote.InventoryBand.selector, ONE_UBTC, p.minBase, p.maxBase)
        );
        this.callQuote(p, true, true, regs);

        DeskParams memory floor_ = btcParams();
        floor_.minBase = uint128(INVENTORY);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreQuote.InventoryBand.selector, INVENTORY - 99_799_144, floor_.minBase, floor_.maxBase
            )
        );
        this.callQuote(floor_, true, false, registers(ONE_UBTC_AT_L1_BID, 0));
    }

    // ---- the map: can add a lean, can never be the reason for a stale one ----

    function test_staleMap_isIgnored() public {
        vm.warp(1_760_000_000);
        DeskParams memory p = btcParams();
        p.mapOracle = address(mapOracle);
        mapOracle.update(BTC, 10_000_000, 0);

        uint256 leaning = bidOut(p, ONE_UBTC, 0);
        vm.warp(block.timestamp + MAP_MAX_AGE + 1);
        uint256 forgotten = bidOut(p, ONE_UBTC, 0);

        assertEq(uint8(coreQuote.regime(p).lean), uint8(Side.None), "a stale map cannot hold a lean");
        assertEq(forgotten, bidOut(btcParams(), ONE_UBTC, 0), "and the answer is the book-only one");
        assertGt(leaning, forgotten, "which is worse for the taker than the lean was");
    }

    /// @dev The quiet 999 book dislocates 4 bps, nowhere near stressBps. The map is the only thing
    ///      that can move this quote, and it can only ever move it toward absorbing.
    function test_freshMap_leansWithoutDislocation() public {
        vm.warp(1_760_000_000);
        DeskParams memory p = btcParams();
        p.mapOracle = address(mapOracle);

        assertEq(uint8(coreQuote.regime(p).lean), uint8(Side.None), "no map, no lean");
        mapOracle.update(BTC, MAP_MIN_NOTIONAL, 0);

        Regime memory r = coreQuote.regime(p);
        assertEq(uint8(r.lean), uint8(Side.Bid), "a loaded map leans the bid on its own");
        assertEq(r.dislocationBps, 4, "on a book the threshold would never have fired on");
        assertTrue(r.mapFresh, "fresh");
        assertGt(bidOut(p, ONE_UBTC, 0), bidOut(btcParams(), ONE_UBTC, 0), "and the quote follows");
    }

    function test_smallMap_isIgnored() public {
        vm.warp(1_760_000_000);
        DeskParams memory p = btcParams();
        p.mapOracle = address(mapOracle);
        mapOracle.update(BTC, MAP_MIN_NOTIONAL - 1, 0);
        assertEq(uint8(coreQuote.regime(p).lean), uint8(Side.None), "under the maker's notional");
    }

    function test_noMapOracle_isBookOnly() public {
        vm.warp(1_760_000_000);
        mapOracle.update(BTC, 10_000_000, 0);
        DeskParams memory p = btcParams(); // mapOracle stays address(0)

        assertEq(uint8(coreQuote.regime(p).lean), uint8(Side.None), "a map nobody points at is not read");
        assertEq(bidOut(p, ONE_UBTC, 0), 79_391_898_000, "the quiet quote, unchanged");
    }

    /// @dev A map oracle that reverts is a keeper malfunction, and a keeper malfunction may not
    ///      take the desk down. It degrades to book-only, which is the same as silence.
    function test_revertingMapOracle_degradesToBookOnly() public {
        DeskParams memory p = btcParams();
        p.mapOracle = address(new RevertingMapOracle());
        assertEq(uint8(coreQuote.regime(p).lean), uint8(Side.None));
        assertEq(bidOut(p, ONE_UBTC, 0), 79_391_898_000, "the quiet quote, unchanged");
    }

    // ---- SwapVM invariants ----

    function test_exactOut_mirrorsExactIn() public view {
        DeskParams memory p = btcParams();
        uint256 out = bidOut(p, ONE_UBTC, 0);

        SwapRegisters memory regs = registers(0, out);
        uint256 amountIn = quote(p, false, true, regs).amountIn;
        assertEq(amountIn, ONE_UBTC, "the exact-out leg lands back on the exact-in one");
    }

    function test_takerAmountUntouched() public view {
        DeskParams memory p = btcParams();

        SwapRegisters memory exactIn = quote(p, true, true, registers(ONE_UBTC, 0));
        assertEq(exactIn.amountIn, ONE_UBTC, "exact-in: the taker's leg is not ours to move");

        SwapRegisters memory exactOut = quote(p, false, true, registers(0, ONE_UBTC_AT_L1_BID));
        assertEq(exactOut.amountOut, ONE_UBTC_AT_L1_BID, "exact-out: likewise");
        assertEq(exactOut.balanceIn, 0, "balances are Aqua's, not the strategy's");
        assertEq(exactOut.balanceOut, INVENTORY);
    }

    /// @dev Quote mode and swap mode reach the same `view` body, so the flag cannot change an
    ///      answer. The router-level equality is `test_quoteEqualsSwap`, on the ship harness.
    function test_staticContextFlag_isIgnored() public view {
        DeskParams memory p = btcParams();
        (uint256 pc, uint256 chopped, SwapRegisters memory asQuote) =
            coreQuote.extruction(true, NEXT_PC, query(true, true), registers(ONE_UBTC, 0), encoded(p), "");
        (,, SwapRegisters memory asSwap) =
            coreQuote.extruction(false, NEXT_PC, query(true, true), registers(ONE_UBTC, 0), encoded(p), "");

        assertEq(asQuote.amountOut, asSwap.amountOut, "one code path, one answer");
        assertEq(pc, NEXT_PC, "no jumps");
        assertEq(chopped, 0, "nothing chopped from takerData");
    }

    /// @dev The desk's own two prices, for the page. Raw HyperCore units, same axis as L1's.
    function test_bounds_bracketsL1WhenQuiet() public view {
        (uint256 bidPx, uint256 askPx, Side lean) = coreQuote.bounds(btcParams());
        assertEq(uint8(lean), uint8(Side.None));
        assertLt(bidPx, QUIET_BID, "outside L1's bid");
        assertGt(askPx, QUIET_ASK, "outside L1's ask");
    }

    function test_bounds_neverCrossesL1UnderStress() public {
        setBook(QUIET_BID, QUIET_ASK, 780_000, QUIET_ORACLE);
        (uint256 bidPx,, Side lean) = coreQuote.bounds(btcParams());
        assertEq(uint8(lean), uint8(Side.Bid));
        assertEq(bidPx, QUIET_ASK, "the lean is clamped at L1's ask, same as the quote");
    }

    // ---- still on the ship harness ----

    function test_quoteEqualsSwap() public {
        vm.skip(true);
    }

    function test_plainXycUnchangedOnOfficialRouter() public {
        vm.skip(true);
    }

    function test_deathMetric_amountOutMovesWithBook() public {
        vm.skip(true);
    }

    // ---- helpers ----

    function encoded(DeskParams memory p) internal pure returns (bytes memory) {
        return DeskParamsLib.encode(p);
    }

    function registers(uint256 amountIn, uint256 amountOut) internal pure returns (SwapRegisters memory) {
        return SwapRegisters({ balanceIn: 0, balanceOut: INVENTORY, amountIn: amountIn, amountOut: amountOut });
    }

    function query(bool isExactIn, bool bidSide) internal view returns (SwapQuery memory) {
        (address tokenIn, address tokenOut) =
            bidSide ? (address(ubtc), address(usdt0)) : (address(usdt0), address(ubtc));
        return SwapQuery({
            orderHash: bytes32(uint256(1)),
            maker: address(this),
            taker: address(taker),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            isExactIn: isExactIn
        });
    }

    function quote(DeskParams memory p, bool isExactIn, bool bidSide, SwapRegisters memory regs)
        internal
        view
        returns (SwapRegisters memory updated)
    {
        (,, updated) = coreQuote.extruction(true, NEXT_PC, query(isExactIn, bidSide), regs, encoded(p), "");
    }

    /// @dev `curve` is what an XYCSwap ahead of the Extruction left in the register; 0 is none.
    function bidOut(DeskParams memory p, uint256 amountIn, uint256 curve) internal view returns (uint256) {
        return quote(p, true, true, registers(amountIn, curve)).amountOut;
    }

    function askOut(DeskParams memory p, uint256 amountIn, uint256 curve) internal view returns (uint256) {
        return quote(p, true, false, registers(amountIn, curve)).amountOut;
    }

    /// @dev External so vm.expectRevert has a call frame to catch.
    function callQuote(DeskParams memory p, bool isExactIn, bool bidSide, SwapRegisters memory regs)
        external
        view
        returns (SwapRegisters memory)
    {
        return quote(p, isExactIn, bidSide, regs);
    }
}

contract RevertingMapOracle {
    fallback() external {
        revert("keeper is down");
    }
}
