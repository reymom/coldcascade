// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { DeskTest } from "./DeskTest.sol";
import { DemoToken } from "../../src/DemoToken.sol";

/// @title BlindTakers
/// @notice The two takers the replay is driven by, and the reason its numbers mean anything.
///
///         A taker routes on price. It does not know which maker is which, and it must not be able
///         to find out: if the routing function can tell the desk from the control, then whatever
///         separation the screen shows was handed over rather than won. That is not a style
///         preference, it is the whole claim — the desk only deserves more size when its quote was
///         better in that minute.
///
///         So blindness here is structural, not a promise:
///
///         1. The only thing either taker learns about a maker is the number that comes back from
///            `quote`. A `Line` carries an order and a strategy hash and nothing else. No
///            `DeskParams`, no `regime()`, no `lean`, no hook address, no program bytes.
///         2. Everything else a taker consults — the pair, the price scale, L1's touch, spot — is
///            in `Market`, which is built from the tape and is the same for every maker.
///         3. One routine runs against every maker. There is no per-maker branch anywhere below,
///            and no argument that would let one exist.
///
///         `Oct10Replay.test_takers_areBlind` is what enforces it: ship the same program into two
///         slots and the two lines have to come out on top of each other. Any leak — a branch on
///         index, a tie broken by position, a special case — separates them and fails that test.
abstract contract BlindTakers is DeskTest {
    /// @notice A maker, as a taker sees it. Deliberately not enough to identify one.
    struct Line {
        ISwapVM.Order order;
        bytes32 hash;
    }

    /// @notice The minute, as a taker sees it. Public market data, identical for every maker.
    struct Market {
        address base;
        address quote;
        uint64 pxNum;
        uint64 pxDen;
        uint64 bid;
        uint64 ask;
        uint256 spot;
    }

    /// @notice What one line did in one minute. Both sides, because a taker is not promised that a
    ///         minute is one-directional.
    struct Fill {
        uint256 boughtBase; // the maker bought base ...
        uint256 paidQuote; // ... and paid this
        uint256 soldBase; // the maker sold base ...
        uint256 gotQuote; // ... and took this
    }

    /// @notice What the arbitrageur did to one line in one minute, in whole USD.
    struct Bleed {
        uint256 notional; // traded against this maker
        uint256 profit; // extracted from it, closed at L1's own touch
    }

    /// @dev The arb's size search, and the reason it is shaped like this.
    ///
    ///      A linear grid is what a first attempt reaches for and it is wrong here: the optimum for
    ///      a small dislocation sits many orders of magnitude below the capacity bound, so one
    ///      linear step overshoots it and walks the maker straight through fair value and out the
    ///      other side. That failure looks like a working arbitrageur and produces plausible
    ///      nonsense — a maker left mispriced in the opposite direction, and an LVR number with no
    ///      relation to anything.
    ///
    ///      So: a geometric ladder to bracket, then a golden-section narrowing inside the bracket.
    ///      Profit is unimodal in size for every curve in this suite, so the bracket is real, and
    ///      golden section costs **one** quote an iteration where a ternary search costs two. That
    ///      matters: every probe is a full router quote, Solidity's allocator never gives the memory
    ///      back, and memory is priced quadratically — the search's width is bounded by what one
    ///      transaction can hold, not by what is elegant.
    uint256 internal constant ARB_LADDER = 14;
    uint256 internal constant ARB_REFINE = 8;

    /// @dev Built once. It is the same bytes on every call, and rebuilding it per quote is most of
    ///      the memory the search would otherwise leave behind.
    bytes internal _blindTakerData;

    function setUp() public virtual override {
        super.setUp();
        _blindTakerData = deskTakerData(address(taker), true, false);
    }

    // ---- what a taker may ask ----

    /// @notice One exact-in quote through the official router. The only channel between a taker and
    ///         a maker in this harness.
    /// @dev A revert is an answer, not an error: an inventory band that cannot take the fill, a
    ///      balance that cannot pay it, a book the maker refuses to quote on. A router facing a
    ///      maker that will not fill moves on to the next one, so this returns zero and the caller
    ///      does the same. Identical treatment for every line, which is the point.
    function quoteOut(Line memory line, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        if (amountIn == 0) return 0;
        try swapVM.asView().quote(line.order, tokenIn, tokenOut, amountIn, _blindTakerData) returns (
            uint256, uint256 amountOut, bytes32
        ) {
            return amountOut;
        } catch {
            return 0;
        }
    }

    /// @notice Settle exact-in against one line, funding the taker for exactly the clip.
    function takeFrom(Line memory line, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 spent, uint256 received)
    {
        DemoToken(tokenIn).mint(address(taker), amountIn);
        return taker.swap(line.order, tokenIn, tokenOut, amountIn, deskTakerData(address(taker), true, false));
    }

    // ---- the flow taker ----

    /// @notice The forced seller. No discretion, no view, no patience: it has size to move and it
    ///         moves it into whatever is bid, best price first, walking down as each maker's curve
    ///         gives way.
    /// @param rot Where the scan starts. Rotating it means a tie is not a standing advantage for
    ///        whoever happens to be at index zero — the one place position could leak into price.
    /// @dev The pool is a parameter of the tape, never of a regime. The same notional is offered in
    ///      the quiet as in a cascade; who ends up with it is settled here, by price, one clip at a
    ///      time.
    function routeFlow(
        Line[] memory lines,
        Fill[] memory out,
        Market memory m,
        bool makerBuysBase,
        uint256 totalIn,
        uint256 clips,
        uint256 rot
    ) internal {
        if (totalIn == 0 || clips == 0) return;
        (address tokenIn, address tokenOut) = makerBuysBase ? (m.base, m.quote) : (m.quote, m.base);

        uint256 clip = totalIn / clips;
        if (clip == 0) return;

        for (uint256 c = 0; c < clips; ++c) {
            (uint256 best, uint256 at) = bestBid(lines, tokenIn, tokenOut, clip, rot + c);
            if (best == 0) break;

            (uint256 spent, uint256 received) = takeFrom(lines[at], tokenIn, tokenOut, clip);
            if (makerBuysBase) {
                out[at].boughtBase += spent;
                out[at].paidQuote += received;
            } else {
                out[at].soldBase += received;
                out[at].gotQuote += spent;
            }
        }
    }

    /// @dev Which line pays most for this clip. Strict `>` from a rotating start, so the winner is
    ///      the first best rather than the lowest-indexed best.
    function bestBid(Line[] memory lines, address tokenIn, address tokenOut, uint256 clip, uint256 rot)
        internal
        view
        returns (uint256 best, uint256 at)
    {
        uint256 n = lines.length;
        for (uint256 k = 0; k < n; ++k) {
            uint256 i = (k + rot) % n;
            uint256 got = quoteOut(lines[i], tokenIn, tokenOut, clip);
            if (got > best) (best, at) = (got, i);
        }
    }

    // ---- the arb taker ----

    /// @notice The one who gets paid for a maker being late.
    ///
    ///         A maker is arbitrageable when someone can trade against it and unwind at the
    ///         reference venue for more than they paid. The reference is Hyperliquid's own touch,
    ///         read out of the same book the quote read — the same reference `Inarbitrable.t.sol`
    ///         asserts against per call. Not spot: spot is a different instrument and closing there
    ///         is basis risk, not arbitrage, and a taker that pretended otherwise would report a
    ///         profit it could not actually take.
    ///
    ///         This is where sitting outside the touch gets paid, and it is also what keeps the
    ///         other line honest — an AMM only has a sane bid when the forced seller arrives
    ///         because someone has already repriced it and charged it for the privilege.
    ///
    /// @dev Both directions, every line, same routine. It has no idea that one of these makers has
    ///      no size that works; it looks for one and does not find it.
    function runArb(Line[] memory lines, Bleed[] memory out, Market memory m, uint16 edgeBps) internal {
        for (uint256 i = 0; i < lines.length; ++i) {
            arbOne(lines[i], out[i], m, true, edgeBps);
            arbOne(lines[i], out[i], m, false, edgeBps);
        }
    }

    /// @param sellIntoMaker true: sell base to the maker and buy it back at L1's ask.
    ///        false: buy base from the maker and sell it into L1's bid.
    function arbOne(Line memory line, Bleed memory out, Market memory m, bool sellIntoMaker, uint16 edgeBps)
        internal
    {
        uint256 cap = arbCapacity(line, m, sellIntoMaker);
        if (cap == 0) return;

        (uint256 size, uint256 profit) = bestArbSize(line, m, sellIntoMaker, cap);
        if (size == 0 || profit == 0) return;

        // The floor a real arbitrageur has: gas, fees, and the risk of being second. Below it the
        // dislocation is left standing, which is why a maker drifts between minutes.
        uint256 notionalQuote = sellIntoMaker ? legQuote(m, size, m.ask) : size;
        uint256 profitQuote = sellIntoMaker ? legQuote(m, profit, m.ask) : profit;
        if (profitQuote * BPS_DEN < notionalQuote * edgeBps) return;

        (address tokenIn, address tokenOut) = sellIntoMaker ? (m.base, m.quote) : (m.quote, m.base);
        (uint256 spent, uint256 received) = takeFrom(line, tokenIn, tokenOut, size);

        // Realised, from the settled swap rather than from the quote that predicted it.
        uint256 back = sellIntoMaker ? legBase(m, received, m.ask) : legQuote(m, received, m.bid);
        uint256 realisedQuote = sellIntoMaker
            ? (back > spent ? legQuote(m, back - spent, m.ask) : 0)
            : (back > spent ? back - spent : 0);

        out.notional += notionalQuote / 1e6;
        out.profit += realisedQuote / 1e6;
    }

    /// @dev How much the maker could possibly take, from its own side of the book. A size beyond it
    ///      is refused by the router anyway; bounding the ladder here keeps the search inside the
    ///      range where a quote is an answer rather than a revert.
    function arbCapacity(Line memory line, Market memory m, bool sellIntoMaker) internal view returns (uint256) {
        (uint256 base_, uint256 quote_) = aqua.safeBalances(maker, address(swapVM), line.hash, m.base, m.quote);
        return sellIntoMaker ? legBase(m, quote_, m.ask) : legQuote(m, base_, m.bid);
    }

    /// @dev What one round trip through this maker returns, net, in the unit that went in.
    function arbProfit(Line memory line, Market memory m, bool sellIntoMaker, uint256 size)
        internal
        view
        returns (uint256)
    {
        if (size == 0) return 0;
        (address tokenIn, address tokenOut) = sellIntoMaker ? (m.base, m.quote) : (m.quote, m.base);
        uint256 got = quoteOut(line, tokenIn, tokenOut, size);
        if (got == 0) return 0;

        // Close at L1's touch, crossing it in the direction that costs. The arbitrageur is given
        // every rounding and charged no fee and no depth, which is the most generous exit there is.
        uint256 back = sellIntoMaker ? legBase(m, got, m.ask) : legQuote(m, got, m.bid);
        return back > size ? back - size : 0;
    }

    /// @dev Ladder, then narrow. Returns zero when nothing at any size comes back whole, which is
    ///      the answer for a maker whose quote is bounded by the venue it would be closed against.
    function bestArbSize(Line memory line, Market memory m, bool sellIntoMaker, uint256 cap)
        internal
        view
        returns (uint256 size, uint256 profit)
    {
        for (uint256 k = 1; k <= ARB_LADDER; ++k) {
            uint256 s = cap >> (ARB_LADDER - k);
            if (s == 0) continue;
            uint256 p = arbProfit(line, m, sellIntoMaker, s);
            if (p > profit) (profit, size) = (p, s);
        }
        // Nothing at any size came back whole. That is the answer for a maker whose quote is bounded
        // by the very venue it would be closed against, and it is the cheap path on purpose: the
        // ladder alone settles it, with no refinement to pay for.
        if (size == 0) return (0, 0);

        (uint256 lo, uint256 hi) = (size >> 1, size < (cap >> 1) ? size << 1 : cap);
        (uint256 a, uint256 b) = (lo + (hi - lo) * 382 / 1000, lo + (hi - lo) * 618 / 1000);
        (uint256 pa, uint256 pb) = (arbProfit(line, m, sellIntoMaker, a), arbProfit(line, m, sellIntoMaker, b));

        for (uint256 it = 0; it < ARB_REFINE && hi - lo > 2; ++it) {
            if (pa < pb) {
                (lo, a, pa) = (a, b, pb);
                b = lo + (hi - lo) * 618 / 1000;
                pb = arbProfit(line, m, sellIntoMaker, b);
            } else {
                (hi, b, pb) = (b, a, pa);
                a = lo + (hi - lo) * 382 / 1000;
                pa = arbProfit(line, m, sellIntoMaker, a);
            }
        }
        if (pa > profit) (profit, size) = (pa, a);
        if (pb > profit) (profit, size) = (pb, b);
    }

    // ---- scale ----

    uint256 internal constant BPS_DEN = 10_000;

    /// @dev base units -> quote units at a raw L1 price.
    function legQuote(Market memory m, uint256 baseAmount, uint64 rawPx) internal pure returns (uint256) {
        return baseAmount * uint256(rawPx) * m.pxNum / m.pxDen;
    }

    /// @dev quote units -> base units at a raw L1 price.
    function legBase(Market memory m, uint256 quoteAmount, uint64 rawPx) internal pure returns (uint256) {
        return quoteAmount * m.pxDen / (uint256(rawPx) * m.pxNum);
    }
}
