// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";
import { SwapQuery } from "@1inch/swap-vm/src/libs/VM.sol";

import { DeskTest } from "./base/DeskTest.sol";
import { Book } from "../src/interfaces/ICoreReader.sol";
import { DeskParams, DeskParamsLib } from "../src/libs/DeskParams.sol";
import { Side } from "../src/libs/Regime.sol";

/// @title InarbitrableTest
/// @notice The half of the claim that is true in every block, not twice a year.
///
///         A maker is arbitraged when someone can buy from it and sell at the reference venue for
///         more than they paid. That profit is the LP's loss-versus-rebalancing, and it exists
///         because the maker's price was set at some earlier time than the trade that takes it.
///         Every AMM has that gap. This one does not: the quote is computed from Hyperliquid's own
///         book *inside the call that settles the swap*, and the last thing it does is clamp
///         itself to what crossing L1 would have paid.
///
///         So the round trip is asserted directly. Take the desk's quote, close the position at
///         L1's own touch in the same book the quote read, and count what came back. It is never
///         more than what went in — in the quiet, in a lean, on either side, exact-in or exact-out,
///         with or without a curve ahead of the bound, over a fuzzed book.
///
/// @dev The arbitrageur is given every rounding: `back` ceils, so a fraction of a unit is credited
///      to them and never to the maker. The close is priced at L1's touch with no fee and no
///      depth limit, which is the most generous exit that exists. Real depth and real taker fees
///      only move these numbers further negative.
///
///      What this does **not** claim: that the desk cannot lose. It can — the reference price
///      itself moves after a fill, and that is inventory risk, which is what the markout measures
///      and what the cover leg is for. LVR is the loss to someone holding a *better price than
///      yours at the same instant*. That one is zero here by construction.
contract InarbitrableTest is DeskTest {
    uint256 internal constant NEXT_PC = 11;
    uint256 internal constant ONE_UBTC = 1e8;
    /// @dev One UBTC valued at the quiet L1 bid, the same constant `CoreQuoteTest` pins.
    uint256 internal constant ONE_UBTC_AT_L1_BID = 79_551_000_000;

    // ---- the quiet: the round trip loses the whole band ----

    /// @dev Buy a UBTC's worth of quote off the desk's bid, buy the base back at L1's offer. The
    ///      arbitrageur is left with less base than they started with, by the desk's own 20 bps
    ///      plus the 0.13 bps of L1 spread they had to cross to get out.
    function test_quiet_sellToTheDeskAndBuyBackOnL1_loses() public view {
        (uint256 paid, uint256 back) = roundTrip(btcParams(), true, true, ONE_UBTC, 0);
        assertEq(paid, ONE_UBTC);
        assertEq(back, 99_798_746, "0.99798746 UBTC comes back out of a whole one");
        assertEq(bps(paid, back), -20, "the round trip loses the band");
    }

    /// @dev The mirror. Buy base off the desk's ask, sell it into L1's bid.
    function test_quiet_buyFromTheDeskAndSellOnL1_loses() public view {
        (uint256 paid, uint256 back) = roundTrip(btcParams(), false, true, ONE_UBTC_AT_L1_BID, 0);
        assertEq(paid, ONE_UBTC_AT_L1_BID);
        assertEq(back, 79_391_217_044, "159 782 956 units of USDT0 short of round");
        assertEq(bps(paid, back), -20, "the same band, from the other side");
    }

    // ---- the lean: the clamp is what stops it at zero ----

    /// @dev Leaning is the desk deliberately quoting a better price than it would in the quiet, and
    ///      it is the moment an arbitrage would appear if anything were going to. It does not,
    ///      because the lean is clamped at L1's own crossing price: the desk walks all the way up
    ///      to L1's offer and stops on it. The round trip is *exactly* zero, which is the tightest
    ///      this can ever be — never a wei better for the taker than crossing L1 itself.
    function test_leaningBid_roundTripIsExactlyZero() public {
        setBook(QUIET_BID, QUIET_ASK, 780_000, QUIET_ORACLE);
        DeskParams memory p = btcParams();
        assertEq(uint8(coreQuote.regime(p).lean), uint8(Side.Bid), "the fixture must actually lean");

        (uint256 paid, uint256 back) = roundTrip(p, true, true, ONE_UBTC, 0);
        assertEq(back, paid, "at the touch, and not through it");
    }

    function test_leaningAsk_roundTripIsExactlyZero() public {
        setBook(QUIET_BID, QUIET_ASK, QUIET_MARK, 780_000);
        DeskParams memory p = btcParams();
        assertEq(uint8(coreQuote.regime(p).lean), uint8(Side.Ask), "the fixture must actually lean");

        (uint256 paid, uint256 back) = roundTrip(p, false, true, ONE_UBTC_AT_L1_BID, 0);
        assertEq(back, paid, "at the touch, and not through it");
    }

    // ---- the property, over a fuzzed book ----

    /// @notice No book, no parameter set, no size and no curve produces a profitable round trip,
    ///         on either side, exact-in or exact-out.
    /// @dev The four combinations run against one book in one call, so a counterexample names the
    ///      book that produced it rather than four unrelated ones. `curve` is what an XYCSwap
    ///      ahead of the bound left in the register — including values far more generous than the
    ///      book, which is exactly the stale price the clamp exists to cut back.
    function testFuzz_noRoundTripEverProfits(
        uint64 bidRaw,
        uint64 spread,
        uint64 markRaw,
        uint64 oracleRaw,
        uint16 quietRaw,
        uint16 leanRaw,
        uint16 stressRaw,
        uint128 sizeRaw,
        uint128 curveRaw
    ) public {
        uint64 bid = uint64(bound(bidRaw, 1, 10_000_000));
        uint64 ask = uint64(bound(spread, 0, 1_000_000)) + bid;
        setBook(bid, ask, uint64(bound(markRaw, 1, 10_000_000)), uint64(bound(oracleRaw, 1, 10_000_000)));

        DeskParams memory p = btcParams();
        p.quietBps = uint16(bound(quietRaw, 0, 9_999));
        p.leanBps = uint16(bound(leanRaw, 0, 9_999));
        p.stressBps = uint16(bound(stressRaw, 0, 10_000));

        uint256 curve = bound(curveRaw, 0, 1e18);
        uint256 base = bound(sizeRaw, 1e3, 1e14);          // 0.00001 to 1 000 000 UBTC
        uint256 quoteAmount = bound(sizeRaw, 1e6, 1e18);   // $1 to $1 000 000 000 000

        (uint256 paid, uint256 back) = roundTrip(p, true, true, base, curve);
        assertLe(back, paid, "bid side, exact in");
        (paid, back) = roundTrip(p, false, true, quoteAmount, curve);
        assertLe(back, paid, "ask side, exact in");
        (paid, back) = roundTrip(p, true, false, quoteAmount, curve);
        assertLe(back, paid, "bid side, exact out");
        (paid, back) = roundTrip(p, false, false, base, curve);
        assertLe(back, paid, "ask side, exact out");
    }

    /// @notice The same property with the lean forced by the map rather than by the book, so the
    ///         one input taken on trust is inside the fuzz too.
    /// @dev A map can only ever *add* a lean, and a lean is the aggressive direction. If a
    ///      compromised keeper could open an arbitrage, this is where it would show.
    function testFuzz_aLyingMapCannotOpenAnArbitrage(uint64 bidRaw, uint64 spread, uint128 notional, uint128 sizeRaw)
        public
    {
        uint64 bid = uint64(bound(bidRaw, 1, 10_000_000));
        uint64 ask = uint64(bound(spread, 0, 1_000_000)) + bid;
        setBook(bid, ask, bid, bid);   // no dislocation at all: every lean here came from the map

        DeskParams memory p = btcParams();
        p.mapOracle = address(demoMap);
        demoMap.update(BTC, uint128(bound(notional, MAP_MIN_NOTIONAL, type(uint96).max)), 0);
        assertEq(uint8(coreQuote.regime(p).lean), uint8(Side.Bid), "the map alone put the desk into a lean");

        (uint256 paid, uint256 back) = roundTrip(p, true, true, bound(sizeRaw, 1e3, 1e14), 0);
        assertLe(back, paid, "a map that lies costs the maker a spread, never a round trip");
    }

    // ---- on the official router: the desk and the control, at the same instant ----

    /// @notice The whole argument in one test.
    ///
    ///         Two makers on 1inch's router, same pair, same inventory, both priced at the book
    ///         they were shipped at. The book then moves 12%, which is the 10 October 2025 move.
    ///         The control is a constant product and has not heard about it, so it is now paying
    ///         the old price and an arbitrageur takes 1 355 bps out of it in one round trip. The
    ///         desk carries *the same constant product* — `XYCSwap || Extruction(CoreQuote)` — and
    ///         the curve inside it wants to pay the same stale price. The bound is what stops it.
    ///
    ///         This is LVR: the control's loss is entirely that its price was set before the trade.
    ///         The desk's price is set during the trade, so there is nothing to take.
    function test_lvr_theControlIsArbitrableAfterAMove_theDeskIsNot() public {
        DeskParams memory p = btcParams();
        // Reserves that price the curve at L1's own bid, so neither maker starts mispriced.
        uint256 reserveBase = 10e8;
        uint256 reserveQuote = uint256(QUIET_BID) * reserveBase / 1000;

        ISwapVM.Order memory desk = deskOrder(p, keccak256("inarbitrable-desk"));
        ISwapVM.Order memory control = controlOrder(p, keccak256("inarbitrable-control"));
        shipFunded(desk, p, reserveBase, reserveQuote);
        shipFunded(control, p, reserveBase, reserveQuote);

        uint256 size = 1e6;   // 0.01 UBTC, small enough that curve slippage is not the story

        assertEq(routerRoundTripBps(desk, p, size), -20, "the desk is not arbitrable at rest");
        assertEq(routerRoundTripBps(control, p, size), -10, "nor is a curve priced at the book");

        // The book moves and nothing else does. Same block, same inventory, same two orders.
        setBook(700_000, 700_010, 690_000, 700_000);

        int256 controlAfter = routerRoundTripBps(control, p, size);
        int256 deskAfter = routerRoundTripBps(desk, p, size);

        assertEq(controlAfter, 1_352, "the stale curve is now worth 13.5% to an arbitrageur");
        assertEq(deskAfter, 0, "the desk moved with the book and stopped on L1's own offer");
        assertEq(uint8(coreQuote.regime(p).lean), uint8(Side.Bid), "and it is leaning while it does it");
    }

    // ---- helpers ----

    /// @notice Quote the desk, then close the position at L1's own touch in the same book.
    /// @param bidSide true is the taker selling base to the desk.
    /// @param takerAmount The leg the taker names: `amountIn` when exact-in, `amountOut` when not.
    /// @param curve What an XYCSwap ahead of the bound left in the maker's register.
    /// @return paid What the arbitrageur put in. @return back What closing on L1 returns to them.
    function roundTrip(DeskParams memory p, bool bidSide, bool isExactIn, uint256 takerAmount, uint256 curve)
        internal
        view
        returns (uint256 paid, uint256 back)
    {
        SwapRegisters memory regs = SwapRegisters({
            balanceIn: 0,
            balanceOut: type(uint128).max,
            amountIn: isExactIn ? takerAmount : curve,
            amountOut: isExactIn ? curve : takerAmount,
            amountNetPulled: 0
        });
        (,, SwapRegisters memory updated) =
            coreQuote.extruction(true, NEXT_PC, query(isExactIn, bidSide), regs, DeskParamsLib.encode(p), "");

        return (updated.amountIn, closeOnL1(p, bidSide, updated.amountOut));
    }

    /// @notice What the token the desk handed over is worth back at L1's touch, rounded up.
    /// @dev Rounding up is deliberate: every fraction of a unit goes to the arbitrageur. The exit
    ///      is also free and infinitely deep, which no real one is.
    function closeOnL1(DeskParams memory p, bool bidSide, uint256 got) internal view returns (uint256) {
        Book memory book = precompiles.read(p.perpIndex);
        return bidSide
            ? Math.ceilDiv(got * p.pxDen, uint256(book.ask) * p.pxNum)      // quote back into base, at L1's offer
            : Math.ceilDiv(got * uint256(book.bid) * p.pxNum, p.pxDen);     // base back into quote, at L1's bid
    }

    /// @notice The same round trip through the deployed SwapVM router, in bps of what went in.
    /// @dev Exact-in on the bid side only: this is the direction a forced seller takes, and the
    ///      one an arbitrageur would use against a curve that has not repriced.
    function routerRoundTripBps(ISwapVM.Order memory o, DeskParams memory p, uint256 amountIn)
        internal
        view
        returns (int256)
    {
        (, uint256 amountOut) = quoteRouter(o, p, amountIn, true, true);
        return bps(amountIn, closeOnL1(p, true, amountOut));
    }

    function bps(uint256 paid, uint256 back) internal pure returns (int256) {
        return (int256(back) - int256(paid)) * 10_000 / int256(paid);
    }

    function query(bool isExactIn, bool bidSide) internal view returns (SwapQuery memory) {
        (address tokenIn, address tokenOut) = pair(btcParams(), bidSide);
        return SwapQuery({
            orderHash: bytes32(uint256(1)),
            maker: address(this),
            taker: address(taker),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            isExactIn: isExactIn
        });
    }
}
