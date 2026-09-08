// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";
import { IStaticExtruction, IExtruction } from "@1inch/swap-vm/src/instructions/Extruction.sol";

import { ICoreReader, Book } from "./interfaces/ICoreReader.sol";
import { IMapOracle, LiquidationMap } from "./interfaces/IMapOracle.sol";
import { DeskParams, DeskParamsLib } from "./libs/DeskParams.sol";
import { Regime, Side, RegimeLib } from "./libs/Regime.sol";

/// @title CoreQuote
/// @notice The Extruction target of a desk program: `XYCSwap || Extruction(CoreQuote, DeskParams)`.
///         Bounds the curve's leg by Hyperliquid's own book, read in the same call, and moves the
///         absorbing side inside the L1 spread when the book dislocates from oracle or when a fresh
///         liquidation map says mark is walking into forced flow.
/// @dev One code path for quote and swap. `view` in both, because a precompile read is pure in both.
///      No storage, no owner, no upgrade. The maker's parameters arrive in `args`, frozen at ship().
///      SwapVM guarantees the taker-specified leg is untouched, so a fill the inventory band cannot
///      take reverts rather than being resized.
contract CoreQuote is IStaticExtruction, IExtruction {
    using DeskParamsLib for bytes;

    uint256 private constant BPS = 10_000;

    /// @notice Where the book comes from. CorePrecompiles when nested STATICCALL reaches the node,
    ///         BookCache otherwise. Immutable either way.
    ICoreReader public immutable READER;

    /// @dev Same selector as HyperCore.EmptyBook: one condition, one error, whichever reader saw it.
    error EmptyBook(uint32 perpIndex);
    error CrossedBook(uint64 bid, uint64 ask);
    error WrongPair(address tokenIn, address tokenOut);
    error InventoryBand(uint256 baseAfter, uint128 minBase, uint128 maxBase);
    error InvalidSpread(uint16 quietBps, uint16 leanBps);
    error InvalidScale(uint64 pxNum, uint64 pxDen);

    constructor(ICoreReader reader) {
        READER = reader;
    }

    /// @inheritdoc IStaticExtruction
    /// @dev Reads the book, classifies the regime, bounds or leans the curve-filled leg, checks the
    ///      inventory band. Returns nextPC unchanged and chops nothing from takerData.
    ///
    ///      In registers, exact-in on the bid side (taker sells base, maker sets `amountOut`):
    ///
    ///          curve = swap.amountOut                         // 0 if no curve preceded
    ///          bound = amountIn * bid * (1e4 - spread) / 1e4 * pxNum / pxDen
    ///                  spread = leaning ? -leanBps : +quietBps
    ///          out   = leaning ? max(curve, bound) : min(curve, bound)
    ///          out   = min(out, amountIn * ask * pxNum / pxDen)     // never pay above L1 ask
    ///
    ///      The ask side is the mirror on `ask`, with the floor "never sell below L1 bid". Exact-out
    ///      computes `amountIn` instead, with the two selections swapped, because on that leg a
    ///      bigger number is worse for the taker. Rounding always favours the maker: floor on what
    ///      the maker gives, ceil on what it takes.
    function extruction(
        bool,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata
    )
        external
        view
        override(IStaticExtruction, IExtruction)
        returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegisters memory updatedSwap)
    {
        DeskParams memory p = args.decode();
        bool bidSide = _side(p, query.tokenIn, query.tokenOut);

        Book memory book = _book(p.perpIndex);
        Side lean = RegimeLib.classify(book, _map(p.mapOracle, p.perpIndex), p, block.timestamp).lean;
        bool leaning = bidSide ? lean == Side.Bid : lean == Side.Ask;

        // SwapVM guarantees the taker-specified leg survives this call; the other one is ours.
        uint256 takerLeg = query.isExactIn ? swap.amountIn : swap.amountOut;
        uint256 curve = query.isExactIn ? swap.amountOut : swap.amountIn;

        uint256 bound =
            _leg(p, takerLeg, bidSide ? book.bid : book.ask, _mulBps(p, bidSide, leaning), bidSide, query.isExactIn);
        // What L1 itself would charge a taker crossing the spread. The desk never beats it.
        uint256 crossing = _leg(p, takerLeg, bidSide ? book.ask : book.bid, BPS, bidSide, query.isExactIn);

        uint256 filled;
        if (curve == 0) {
            // No curve preceded, so the book is the whole quote. A curve that legitimately filled
            // zero on dust lands here too and is quoted off the book; at that size the two agree.
            filled = bound;
        } else if (query.isExactIn) {
            filled = leaning ? Math.max(curve, bound) : Math.min(curve, bound);
        } else {
            filled = leaning ? Math.min(curve, bound) : Math.max(curve, bound);
        }
        filled = query.isExactIn ? Math.min(filled, crossing) : Math.max(filled, crossing);

        updatedSwap = swap;
        if (query.isExactIn) {
            updatedSwap.amountOut = filled;
        } else {
            updatedSwap.amountIn = filled;
        }

        _requireBand(p, bidSide, swap, updatedSwap);
        return (nextPC, 0, updatedSwap);
    }

    /// @notice The regime this desk would quote under right now. What the page and the keeper read.
    function regime(DeskParams calldata p) external view returns (Regime memory) {
        return RegimeLib.classify(_book(p.perpIndex), _map(p.mapOracle, p.perpIndex), p, block.timestamp);
    }

    /// @notice The desk's own bid and ask next to L1's, in the same raw HyperCore units the reader
    ///         returns, so a page can plot the four numbers on one axis. Scale to token units with
    ///         `pxNum / pxDen`.
    /// @dev A display and keeper read. The quote path does not go through it: `extruction` applies
    ///      the spread inside one expression rather than to a rounded raw tick, so at the resolution
    ///      of a raw tick these agree and below it the quote is the exact one.
    function bounds(DeskParams calldata p) external view returns (uint256 bidPx, uint256 askPx, Side lean) {
        Book memory book = _book(p.perpIndex);
        lean = RegimeLib.classify(book, _map(p.mapOracle, p.perpIndex), p, block.timestamp).lean;

        bidPx = uint256(book.bid) * _mulBps(p, true, lean == Side.Bid) / BPS;
        askPx = Math.ceilDiv(uint256(book.ask) * _mulBps(p, false, lean == Side.Ask), BPS);

        // The same two hard bounds the quote applies, so the picture cannot show a crossed desk.
        if (bidPx > book.ask) bidPx = book.ask;
        if (askPx < book.bid) askPx = book.bid;
    }

    /// @dev True when the taker is selling base, which is the maker buying it: the bid side.
    function _side(DeskParams memory p, address tokenIn, address tokenOut) private pure returns (bool) {
        if (tokenIn == p.base && tokenOut == p.quote) return true;
        if (tokenIn == p.quote && tokenOut == p.base) return false;
        revert WrongPair(tokenIn, tokenOut);
    }

    /// @dev A zero anywhere in the book is an asset with no book, not a price of zero. Index 3 on
    ///      999 is exactly that today. Crossed is the node contradicting itself; neither fills.
    function _book(uint32 perpIndex) private view returns (Book memory book) {
        book = READER.read(perpIndex);
        if (book.bid == 0 || book.ask == 0 || book.mark == 0 || book.oracle == 0) revert EmptyBook(perpIndex);
        if (book.bid > book.ask) revert CrossedBook(book.bid, book.ask);
    }

    /// @dev The map is the one input taken on trust, so it is also the one input allowed to fail.
    ///      A missing, reverting or unset oracle degrades to book-only; it can never stop a quote.
    function _map(address mapOracle, uint32 perpIndex) private view returns (LiquidationMap memory empty) {
        if (mapOracle == address(0)) return empty;
        try IMapOracle(mapOracle).map(perpIndex) returns (LiquidationMap memory fresh) {
            return fresh;
        } catch {
            return empty;
        }
    }

    /// @dev Where the desk's price sits relative to L1's, in bps of the L1 side it is quoted from.
    ///      Outside when quiet, inside when this side is the one absorbing.
    function _mulBps(DeskParams memory p, bool bidSide, bool leaning) private pure returns (uint256) {
        if (p.quietBps >= BPS || p.leanBps >= BPS) revert InvalidSpread(p.quietBps, p.leanBps);
        if (bidSide) return leaning ? BPS + p.leanBps : BPS - p.quietBps;
        return leaning ? BPS - p.leanBps : BPS + p.quietBps;
    }

    /// @dev The maker's leg implied by a raw L1 price scaled by `mulBps / BPS`.
    ///      `bidSide == isExactIn` is the base-to-quote direction, where the leg grows with price;
    ///      otherwise it shrinks with it. Exact-in computes what the maker gives, so it floors;
    ///      exact-out computes what the maker takes, so it ceils.
    function _leg(DeskParams memory p, uint256 amount, uint64 rawPx, uint256 mulBps, bool bidSide, bool isExactIn)
        private
        pure
        returns (uint256)
    {
        if (p.pxNum == 0 || p.pxDen == 0) revert InvalidScale(p.pxNum, p.pxDen);
        uint256 num = uint256(rawPx) * mulBps * p.pxNum;   // quote units per base unit, numerator
        uint256 den = BPS * uint256(p.pxDen);              //                            denominator
        (uint256 n, uint256 d) = (bidSide == isExactIn) ? (amount * num, den) : (amount * den, num);
        return isExactIn ? n / d : Math.ceilDiv(n, d);
    }

    /// @dev The band is checked on the side the fill moves toward: buying base can only walk into
    ///      `maxBase`, selling it can only walk into `minBase`. A fill the band cannot take reverts;
    ///      SwapVM would not let it be silently resized anyway.
    ///
    ///      An `amountOut` above the virtual balance is not the quote's problem — Aqua's pull
    ///      reverts at transfer and the indexer flags it — so the subtraction clamps rather than
    ///      masking that with an arithmetic panic here.
    function _requireBand(
        DeskParams memory p,
        bool bidSide,
        SwapRegisters calldata swap,
        SwapRegisters memory updatedSwap
    ) private pure {
        uint256 baseAfter;
        if (bidSide) {
            baseAfter = swap.balanceIn + updatedSwap.amountIn;
            if (baseAfter > p.maxBase) revert InventoryBand(baseAfter, p.minBase, p.maxBase);
        } else {
            baseAfter = swap.balanceOut > updatedSwap.amountOut ? swap.balanceOut - updatedSwap.amountOut : 0;
            if (baseAfter < p.minBase) revert InventoryBand(baseAfter, p.minBase, p.maxBase);
        }
    }
}
