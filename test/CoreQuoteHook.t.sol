// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";

import { DeskTest } from "./base/DeskTest.sol";
import { CoreQuote } from "../src/CoreQuote.sol";
import { Book } from "../src/interfaces/ICoreReader.sol";
import { DeskParams, DeskParamsLib } from "../src/libs/DeskParams.sol";
import { Regime, Side } from "../src/libs/Regime.sol";
import { FeedMock, FeedReader } from "./mocks/FeedReader.sol";
import { CoreQuoteHook } from "./v4/CoreQuoteHook.sol";
import { PoolManagerStub } from "./v4/PoolManagerStub.sol";
import { Currency, PoolKey, SwapParams, IHooks, Hooks, BalanceDelta, BalanceDeltaLibrary } from "./v4/V4Frame.sol";

/// @title CoreQuoteHookTest
/// @notice The desk's rule in Uniswap v4's frame, against a mock `ICoreReader`. Nothing in this file
///         is deployed and nothing in it could be: there is no chain with a PoolManager and a
///         readable perp book on it. What the file establishes instead, so that `FEEDBACK.md` is a
///         claim with a test behind it rather than an opinion:
///
///         1. the hook and the Extruction return the same number, to the unit, over a fuzzed book —
///            the rule is one function and the frame is the only thing that changed;
///         2. the pool's curve never participates: `amountToSwap` is zero and `Pool.swap` answers
///            with no delta. The hook is the maker; the pool is where it settles;
///         3. the round trip against L1 never profits through v4's frame either;
///         4. one permission bit is the whole difference between a maker and a spectator: the same
///            hook without it answers, is ignored, and the pool's stale curve pays 1 352 bps to an
///            arbitrageur after the 12% move — the README's number, in the other venue's frame;
///         5. a feed cannot lean. The same rule over a Chainlink-shaped reader sees a dislocation of
///            exactly zero on the same move and has no touch to clamp to.
///
/// @dev The reader under the hook is `MockCoreReader`; `setBook` writes it and the etched
///      precompiles together, so every comparison with `coreQuote` is also a comparison across
///      readers. The hook is planted with `deployCodeTo` at an address whose low bits are its
///      permissions, the way v4's own tests plant hooks.
contract CoreQuoteHookTest is DeskTest {
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 internal constant ONE_UBTC = 1e8;
    /// @dev One UBTC at the quiet L1 bid; the constant `CoreQuoteTest` and `InarbitrableTest` pin.
    uint256 internal constant ONE_UBTC_AT_L1_BID = 79_551_000_000;
    /// @dev The pure-book quiet bid for one UBTC, pinned by `test_quiet_noCurve_quotesOffTheBook`.
    uint256 internal constant QUIET_BID_OUT = 79_391_898_000;

    /// @dev The hook's inventory: the same quote-heavy book `CoreQuoteTest` ships with.
    uint256 internal constant HOOK_BASE = 10e8;
    uint256 internal constant HOOK_QUOTE = 900_000e6;

    /// @dev The dislocated, wide book `CoreQuoteTest` uses: 173 bps below oracle, a 10 000 raw spread.
    uint64 internal constant WIDE_BID = 780_000;
    uint64 internal constant WIDE_ASK = 790_000;
    uint64 internal constant WIDE_MARK = 782_000;

    /// @dev The two address bits a hook needs to be the maker: `CoreQuoteHook.PERMISSIONS`.
    uint160 internal constant MAKER_BITS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    CoreQuote internal mockQuote;      // the rule, reading `reader`
    CoreQuoteHook internal hook;       // the rule, in v4's frame
    PoolManagerStub internal manager;
    PoolKey internal key;
    bool internal baseIsCurrency0;

    function setUp() public override {
        super.setUp();
        mockQuote = new CoreQuote(reader);
        manager = new PoolManagerStub();
        hook = deployHook(mockQuote, btcParams(), MAKER_BITS, 0x4444);
        key = poolKey(hook);
    }

    // ---- 1. one rule, two frames ----

    function test_theRuleIsOneFunction_quiet() public {
        PoolManagerStub.Result memory r = manager.swap(key, swapParams(true, true, ONE_UBTC), "");
        (uint256 paid, uint256 got) = legs(r.swapperDelta, true);

        assertEq(paid, ONE_UBTC, "the taker's leg is what it named");
        assertEq(got, QUIET_BID_OUT, "the pure-book quiet bid, the number CoreQuoteTest pins");
        assertEq(got, extructionLeg(coreQuote, btcParams(), true, true, ONE_UBTC), "the deployed rule, through the precompile reader, says the same");
    }

    /// @notice Over any book, any band and any size, on both sides, exact-in and exact-out, the
    ///         hook's answer is the Extruction's answer to the unit.
    function testFuzz_theHookAndTheExtructionAgreeToTheUnit(
        uint64 bidRaw,
        uint64 spread,
        uint64 markRaw,
        uint64 oracleRaw,
        uint16 quietRaw,
        uint16 leanRaw,
        uint16 stressRaw,
        uint128 sizeRaw
    ) public {
        uint64 bid = uint64(bound(bidRaw, 1, 10_000_000));
        uint64 ask = uint64(bound(spread, 0, 1_000_000)) + bid;
        setBook(bid, ask, uint64(bound(markRaw, 1, 10_000_000)), uint64(bound(oracleRaw, 1, 10_000_000)));

        DeskParams memory p = btcParams();
        p.quietBps = uint16(bound(quietRaw, 0, 9_999));
        p.leanBps = uint16(bound(leanRaw, 0, 9_999));
        p.stressBps = uint16(bound(stressRaw, 0, 10_000));
        CoreQuoteHook fuzzed = deployHook(mockQuote, p, MAKER_BITS, 0x5555);
        PoolKey memory k = poolKey(fuzzed);

        uint256 base = bound(sizeRaw, 1e3, 1e14);          // 0.00001 to 1 000 000 UBTC
        uint256 quoteAmount = bound(sizeRaw, 1e6, 1e18);   // $1 to $1 000 000 000 000

        assertAgree(k, p, true, true, base);
        assertAgree(k, p, false, true, quoteAmount);
        assertAgree(k, p, true, false, quoteAmount);
        assertAgree(k, p, false, false, base);
    }

    // ---- 2. the curve is a bystander ----

    function test_theCurveNeverParticipates() public {
        seedAtTheBook();
        (uint256 r0, uint256 r1) = (manager.reserve0(), manager.reserve1());

        PoolManagerStub.Result memory r = manager.swap(key, swapParams(true, true, ONE_UBTC), "");

        assertEq(r.amountToSwap, 0, "the specified delta took the whole amount off the curve");
        assertTrue(r.swapDelta == BalanceDeltaLibrary.ZERO_DELTA, "Pool.swap on a zero amount is no swap");
        assertEq(manager.reserve0(), r0, "the pool's reserves did not move");
        assertEq(manager.reserve1(), r1);
        assertEq(r.hookDelta.amount0(), -r.swapperDelta.amount0(), "what the swapper paid, the hook took");
        assertEq(r.hookDelta.amount1(), -r.swapperDelta.amount1(), "what the swapper got, the hook gave");
    }

    // ---- stress, through the frame ----

    function test_stressDown_theHookLeansInsideL1() public {
        setBook(WIDE_BID, WIDE_ASK, WIDE_MARK, QUIET_ORACLE);
        assertEq(uint8(mockQuote.regime(btcParams()).lean), uint8(Side.Bid), "forced selling leans the bid");

        (, uint256 got) = legs(manager.swap(key, swapParams(true, true, ONE_UBTC), "").swapperDelta, true);
        assertGt(got, ONE_UBTC * WIDE_BID / 1000, "inside the spread, above L1's bid");
        assertLt(got, ONE_UBTC * WIDE_ASK / 1000, "and still below L1's ask");
    }

    function test_theLeanStopsOnL1sOffer() public {
        setBook(QUIET_BID, QUIET_ASK, 780_000, QUIET_ORACLE);
        (, uint256 got) = legs(manager.swap(key, swapParams(true, true, ONE_UBTC), "").swapperDelta, true);
        assertEq(got, ONE_UBTC * QUIET_ASK / 1000, "capped at L1's ask, not at the lean");
        assertEq(got, 79_552_000_000, "the same unit CoreQuoteTest pins");
    }

    // ---- 3. the property, in this frame ----

    /// @notice No book, no band, no size and no side produces a swapper delta that closes at L1's
    ///         touch for more than it cost. `InarbitrableTest` asserts this on the Extruction;
    ///         this is the same claim with v4's accounting between the taker and the rule.
    function testFuzz_noRoundTripEverProfits_inTheV4Frame(
        uint64 bidRaw,
        uint64 spread,
        uint64 markRaw,
        uint64 oracleRaw,
        uint16 quietRaw,
        uint16 leanRaw,
        uint16 stressRaw,
        uint128 sizeRaw
    ) public {
        uint64 bid = uint64(bound(bidRaw, 1, 10_000_000));
        uint64 ask = uint64(bound(spread, 0, 1_000_000)) + bid;
        setBook(bid, ask, uint64(bound(markRaw, 1, 10_000_000)), uint64(bound(oracleRaw, 1, 10_000_000)));

        DeskParams memory p = btcParams();
        p.quietBps = uint16(bound(quietRaw, 0, 9_999));
        p.leanBps = uint16(bound(leanRaw, 0, 9_999));
        p.stressBps = uint16(bound(stressRaw, 0, 10_000));
        PoolKey memory k = poolKey(deployHook(mockQuote, p, MAKER_BITS, 0x5555));

        uint256 base = bound(sizeRaw, 1e3, 1e14);
        uint256 quoteAmount = bound(sizeRaw, 1e6, 1e18);

        assertLe(roundTripBps(k, p, true, true, base), 0, "bid side, exact in");
        assertLe(roundTripBps(k, p, false, true, quoteAmount), 0, "ask side, exact in");
        assertLe(roundTripBps(k, p, true, false, quoteAmount), 0, "bid side, exact out");
        assertLe(roundTripBps(k, p, false, false, base), 0, "ask side, exact out");
    }

    // ---- 4. the bit ----

    /// @notice The same hook, planted at an address without `BEFORE_SWAP_RETURNS_DELTA_FLAG`. The
    ///         manager calls it, it answers, and `Hooks.beforeSwap` drops the answer on the floor:
    ///         the pool's own curve fills at the price it was seeded with. After the 12% move that
    ///         curve is worth 1 352 bps to an arbitrageur in one round trip — the control's number
    ///         in `test_lvr_theControlIsArbitrableAfterAMove_theDeskIsNot` — and the hook with the
    ///         bit is worth exactly zero, leaning, on L1's own offer. The interface expresses the
    ///         rule through that one bit; a hook without it is a fee lever at most.
    function test_withoutTheReturnsDeltaBit_theQuoteNeverReachesTheSwap() public {
        CoreQuoteHook spectator = deployHook(mockQuote, btcParams(), Hooks.BEFORE_SWAP_FLAG, 0x5555);
        PoolKey memory silent = poolKey(spectator);
        DeskParams memory p = btcParams();
        uint256 size = 1e6;   // 0.01 UBTC, the router test's size

        seedAtTheBook();
        PoolManagerStub.Result memory r = manager.swap(silent, swapParams(true, true, size), "");
        assertEq(r.amountToSwap, -int256(size), "the hook answered and the manager did not read it");
        assertTrue(r.hookDelta == BalanceDeltaLibrary.ZERO_DELTA, "so it took nothing and gave nothing");
        assertTrue(r.swapDelta != BalanceDeltaLibrary.ZERO_DELTA, "and the curve did the filling");
        assertEq(closeBps(r.swapperDelta, p, true), -10, "a curve priced at the book is not arbitrable at rest");

        // The book moves and nothing else does. Reseed so both makers face the move from the same inventory.
        setBook(700_000, 700_010, 690_000, 700_000);
        seedAtTheQuietBook();
        assertEq(roundTripBps(silent, p, true, true, size), 1_352, "the stale curve is now worth 13.5% to an arbitrageur");
        assertEq(roundTripBps(key, p, true, true, size), 0, "the hook with the bit moved with the book and stopped on L1's offer");
        assertEq(uint8(mockQuote.regime(p).lean), uint8(Side.Bid), "and it is leaning while it does it");
    }

    // ---- 5. a feed is not a book ----

    /// @notice The same rule, the same parameters, the same 12% move, seen through two readers. The
    ///         book-shaped one sees mark 142 bps under oracle and leans to L1's offer. The
    ///         feed-shaped one — one mid copied into four words — sees a dislocation of exactly
    ///         zero, never leans, and quotes 20 bps under a number that is not a bid. Porting the
    ///         desk to a chain with a feed and no book does not port the mechanism; it keeps the type.
    function test_oracleReader_cannotLean() public {
        FeedMock feed = new FeedMock();
        CoreQuote onFeed = new CoreQuote(new FeedReader(feed));
        PoolKey memory fed = poolKey(deployHook(onFeed, btcParams(), MAKER_BITS, 0x6666));
        DeskParams memory p = btcParams();

        setBook(700_000, 700_010, 690_000, 700_000);   // bid, ask, mark, oracle: the cascade minute
        feed.set(700_000);                              // what a feed reports of the same minute: the index

        Regime memory book = mockQuote.regime(p);
        Regime memory copied = onFeed.regime(p);
        assertEq(book.dislocationBps, 142, "the book says mark is 142 bps under oracle");
        assertEq(uint8(book.lean), uint8(Side.Bid), "and the desk leans");
        assertEq(copied.dislocationBps, 0, "the feed says oracle and mark are the same word");
        assertEq(uint8(copied.lean), uint8(Side.None), "so nothing ever leans");

        (, uint256 fromBook) = legs(manager.swap(key, swapParams(true, true, ONE_UBTC), "").swapperDelta, true);
        (, uint256 fromFeed) = legs(manager.swap(fed, swapParams(true, true, ONE_UBTC), "").swapperDelta, true);
        assertEq(fromBook, ONE_UBTC * 700_010 / 1000, "the book-shaped desk pays L1's own offer");
        assertEq(fromFeed, ONE_UBTC * 700_000 * (10_000 - QUIET_BPS) / 10_000_000, "the feed-shaped one pays 20 bps under the mid");
        assertGt(fromBook, fromFeed, "which is a worse price for the seller being forced out");
    }

    // ---- the band survives the frame ----

    function test_theInventoryBandSurvivesTheFrame() public {
        DeskParams memory p = btcParams();
        p.maxBase = uint128(HOOK_BASE + ONE_UBTC / 2);
        PoolKey memory banded = poolKey(deployHook(mockQuote, p, MAKER_BITS, 0x7777));

        vm.expectRevert(abi.encodeWithSelector(CoreQuote.InventoryBand.selector, HOOK_BASE + ONE_UBTC, p.minBase, p.maxBase));
        manager.swap(banded, swapParams(true, true, ONE_UBTC), "");
    }

    // ---- helpers ----

    /// @dev Plants the hook at an address whose low bits are `flags`, constructor and storage
    ///      included, and gives it the inventory. `prefix` keeps two hooks apart.
    function deployHook(CoreQuote q, DeskParams memory p, uint160 flags, uint16 prefix) internal returns (CoreQuoteHook) {
        address where = address((uint160(prefix) << 144) | flags);
        deployCodeTo("CoreQuoteHook.sol:CoreQuoteHook", abi.encode(q, p), where);
        ubtc.mint(where, HOOK_BASE);
        usdt0.mint(where, HOOK_QUOTE);
        return CoreQuoteHook(where);
    }

    /// @dev Currencies sorted the way v4 sorts them; the fee and spacing mean nothing to this maker.
    function poolKey(CoreQuoteHook h) internal returns (PoolKey memory k) {
        baseIsCurrency0 = address(ubtc) < address(usdt0);
        (address c0, address c1) = baseIsCurrency0 ? (address(ubtc), address(usdt0)) : (address(usdt0), address(ubtc));
        return PoolKey({ currency0: Currency.wrap(c0), currency1: Currency.wrap(c1), fee: 0, tickSpacing: 1, hooks: IHooks(address(h)) });
    }

    /// @dev The bid side is the taker selling base: base is the input currency.
    function swapParams(bool bidSide, bool exactIn, uint256 amount) internal view returns (SwapParams memory) {
        bool zeroForOne = bidSide == baseIsCurrency0;
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactIn ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: 0
        });
    }

    /// @dev What the swapper paid and what it got, read off its delta. Negative is owed, positive is due.
    function legs(BalanceDelta d, bool bidSide) internal view returns (uint256 paid, uint256 got) {
        int128 baseAmt = baseIsCurrency0 ? d.amount0() : d.amount1();
        int128 quoteAmt = baseIsCurrency0 ? d.amount1() : d.amount0();
        (int128 paidSigned, int128 gotSigned) = bidSide ? (baseAmt, quoteAmt) : (quoteAmt, baseAmt);
        assertLe(paidSigned, 0, "the swapper owes what it paid");
        assertGe(gotSigned, 0, "and is owed what it got");
        return (uint256(uint128(-paidSigned)), uint256(uint128(gotSigned)));
    }

    /// @dev The Extruction with no curve ahead of it, which is what the hook hands it.
    function extructionLeg(CoreQuote q, DeskParams memory p, bool bidSide, bool exactIn, uint256 takerAmount)
        internal
        view
        returns (uint256)
    {
        (address tokenIn, address tokenOut) = pair(p, bidSide);
        SwapQuery memory query = SwapQuery({
            orderHash: bytes32(uint256(1)),
            maker: address(this),
            taker: address(taker),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            isExactIn: exactIn
        });
        SwapRegisters memory regs = SwapRegisters({
            balanceIn: 0,
            balanceOut: type(uint128).max,
            amountIn: exactIn ? takerAmount : 0,
            amountOut: exactIn ? 0 : takerAmount,
            amountNetPulled: 0
        });
        (,, SwapRegisters memory filled) = q.extruction(true, 0, query, regs, DeskParamsLib.encode(p), "");
        return exactIn ? filled.amountOut : filled.amountIn;
    }

    function assertAgree(PoolKey memory k, DeskParams memory p, bool bidSide, bool exactIn, uint256 takerAmount) internal {
        (uint256 paid, uint256 got) = legs(manager.swap(k, swapParams(bidSide, exactIn, takerAmount), "").swapperDelta, bidSide);
        uint256 taker_ = exactIn ? paid : got;
        uint256 maker_ = exactIn ? got : paid;
        assertEq(taker_, takerAmount, "the taker's leg survived the frame");
        assertEq(maker_, extructionLeg(coreQuote, p, bidSide, exactIn, takerAmount), "the maker's leg is the Extruction's");
    }

    /// @dev Take the swapper's delta, close it at L1's own touch in the same book, in bps of what
    ///      went in. The close is priced as `InarbitrableTest.closeOnL1` prices it: rounded up,
    ///      free and infinitely deep, which no real exit is.
    function roundTripBps(PoolKey memory k, DeskParams memory p, bool bidSide, bool exactIn, uint256 takerAmount)
        internal
        returns (int256)
    {
        return closeBps(manager.swap(k, swapParams(bidSide, exactIn, takerAmount), "").swapperDelta, p, bidSide);
    }

    /// @dev The close alone, for a delta a test already holds.
    function closeBps(BalanceDelta d, DeskParams memory p, bool bidSide) internal view returns (int256) {
        (uint256 paid, uint256 got) = legs(d, bidSide);
        Book memory book = reader.read(p.perpIndex);
        uint256 back = bidSide
            ? Math.ceilDiv(got * p.pxDen, uint256(book.ask) * p.pxNum)
            : Math.ceilDiv(got * uint256(book.bid) * p.pxNum, p.pxDen);
        return (int256(back) - int256(paid)) * 10_000 / int256(paid);
    }

    /// @dev Reserves that price the stand-in curve at L1's own bid, as the router test prices its
    ///      control — so neither maker starts mispriced.
    function seedAtTheBook() internal {
        Book memory book = reader.read(BTC);
        seedReserves(HOOK_BASE, uint256(book.bid) * HOOK_BASE / 1000);
    }

    function seedAtTheQuietBook() internal {
        seedReserves(HOOK_BASE, uint256(QUIET_BID) * HOOK_BASE / 1000);
    }

    function seedReserves(uint256 base, uint256 quoteAmount) internal {
        baseIsCurrency0 ? manager.seed(base, quoteAmount) : manager.seed(quoteAmount, base);
    }
}
