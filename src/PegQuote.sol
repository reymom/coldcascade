// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";
import { IStaticExtruction, IExtruction } from "@1inch/swap-vm/src/instructions/Extruction.sol";

import { ICoreReader, Book } from "./interfaces/ICoreReader.sol";

/// @title PegQuote
/// @notice The comparator. An oracle-pegged maker: `Extruction(PegQuote, key) || XYCSwap || Salt`,
///         a constant-product curve whose price is Hyperliquid's oracle at its **last refresh**,
///         and which moves in between only when it is traded against.
///
///         This is what most on-chain makers on a perps venue are, and it is here because the
///         other control is not. A plain constant-product curve is the right *ablation* — it is
///         the desk with one instruction removed — but nobody deploys one on a BTC pair, so a
///         reader is entitled to call it a straw man. Nobody deploys the thing below either, they
///         deploy something with more machinery around it, but they all share the property this
///         measures: **the price was set before the trade, by a transaction, on a cadence.**
///
/// @dev The maker's own arithmetic is not written here. `XYCSwap` runs after this and does all of
///      it; the only thing this instruction does is decide what balances that curve is looking at,
///      which is the same as deciding what price it is centred on. Everything else — the depth,
///      the rounding, the exact-out path — is 1inch's, unmodified, exactly as the plain control
///      gets it. A comparator whose curve you wrote yourself is a foil, and this one's is not.
///
///      The re-centring is one number. At a refresh the maker holds `(X, Y)`, and the curve's
///      marginal price is `Y/X`; it should be `P`, the oracle. So the instruction quotes off
///      `(X, Y + offset)` with
///
///          offset = X · P · pxNum / pxDen − Y
///
///      set once per refresh and constant until the next one. Because the *real* balances move
///      with every fill and the offset does not, the curve walks along itself between refreshes
///      exactly as an AMM does, and snaps back to the oracle only when somebody pays for a
///      `refresh`. That is the whole model: still between refreshes, and never looking at the
///      book it will be closed against.
contract PegQuote is IStaticExtruction, IExtruction {
    uint256 private constant BPS = 10_000;

    /// @notice Where the oracle comes from. `CorePrecompiles` on chain, the same reader `CoreQuote`
    ///         is constructed with, so the two makers are never reading different numbers.
    ICoreReader public immutable READER;

    /// @notice What one pegged maker is: the strategy to read balances for, the pair, and the
    ///         cadence its price moves on.
    /// @dev `deviationBps` zero means the deviation trigger is off and the heartbeat alone moves
    ///      the price. It is not "refresh always": a threshold of zero is cleared by every move,
    ///      and a maker configured that way would be repriced by the dust in the last decimal.
    struct Cfg {
        address aqua;
        address swapVM;
        address maker;
        bytes32 strategyHash;
        address base;
        address quote;
        uint32 perpIndex;
        uint64 pxNum;
        uint64 pxDen;
        uint16 deviationBps;
        uint32 heartbeatSeconds;
    }

    /// @notice The price this maker is quoting off, when it was set, and what it costs the curve.
    struct Peg {
        uint64 px;
        uint64 at;
        int256 offset;
    }

    mapping(bytes32 key => Cfg) private _cfg;
    mapping(bytes32 key => Peg) private _peg;

    event Armed(bytes32 indexed key, address indexed maker, bytes32 strategyHash);
    event Repegged(bytes32 indexed key, uint64 px, uint64 at, int256 offset);

    error AlreadyArmed(bytes32 key);
    error NotArmed(bytes32 key);
    error EmptyBook(uint32 perpIndex);
    error WrongPair(address tokenIn, address tokenOut);
    error InvalidScale(uint64 pxNum, uint64 pxDen);
    error NotCentred(bytes32 key);

    constructor(ICoreReader reader) {
        READER = reader;
    }

    /// @notice Point a key at a shipped strategy, once. The program carries the key, so it has to
    ///         be chosen before the order is built and armed after Aqua has hashed it.
    /// @dev Write-once, and permissionless afterwards. There is no owner and no setter: a maker
    ///      that could move its own peg by hand between the quote and the swap would be a maker
    ///      whose two prices are different numbers, which is the one thing `Extruction` forbids.
    function arm(bytes32 key, Cfg calldata cfg) external {
        if (_cfg[key].aqua != address(0)) revert AlreadyArmed(key);
        if (cfg.pxNum == 0 || cfg.pxDen == 0) revert InvalidScale(cfg.pxNum, cfg.pxDen);
        _cfg[key] = cfg;
        emit Armed(key, cfg.maker, cfg.strategyHash);
        _repeg(key, cfg);
    }

    /// @notice Move the price to the oracle, if the cadence says it is time. Anyone may call it.
    /// @return moved Whether this call actually repriced the maker.
    /// @dev **This is the cadence, and it is a transaction.** The number a page reports for this
    ///      line is meaningless without saying how often this was called, which is why it returns
    ///      whether it fired and emits the price it set: the sequence of `Repegged` logs *is* the
    ///      declared cadence, checkable against the run rather than asserted next to it.
    function refresh(bytes32 key) external returns (bool moved) {
        Cfg memory cfg = _cfg[key];
        if (cfg.aqua == address(0)) revert NotArmed(key);

        Peg memory current = _peg[key];
        uint64 px = _oracle(cfg.perpIndex);

        uint256 gap = px > current.px ? px - current.px : current.px - px;
        bool byDeviation = cfg.deviationBps > 0 && gap * BPS >= uint256(current.px) * cfg.deviationBps;
        bool byHeartbeat = block.timestamp >= uint256(current.at) + cfg.heartbeatSeconds;
        if (!byDeviation && !byHeartbeat) return false;

        _repeg(key, cfg);
        return true;
    }

    /// @notice What this maker is quoting off right now, and how old that is.
    function peg(bytes32 key) external view returns (Peg memory) {
        return _peg[key];
    }

    function config(bytes32 key) external view returns (Cfg memory) {
        return _cfg[key];
    }

    /// @inheritdoc IStaticExtruction
    /// @dev Replaces the curve's view of the balances and touches nothing else: the amounts are
    ///      untouched because nothing has computed them yet, `nextPC` comes back unchanged, and no
    ///      taker data is chopped. One code path for quote and swap, and `view` in both, because
    ///      the peg is storage a `refresh` wrote in some earlier transaction — never in this one.
    ///      That is what keeps the two interfaces consistent, which `Extruction` requires and does
    ///      not check.
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
        bytes32 key = bytes32(args[0:32]);
        Cfg memory cfg = _cfg[key];
        if (cfg.aqua == address(0)) revert NotArmed(key);

        bool bidSide = _side(cfg, query.tokenIn, query.tokenOut);
        (uint256 baseBal, uint256 quoteBal) =
            bidSide ? (swap.balanceIn, swap.balanceOut) : (swap.balanceOut, swap.balanceIn);

        // A curve needs both legs. A maker that has traded its whole quote leg away and then some
        // has no price to offer rather than a negative one, and the router treats a revert as an
        // answer — it moves on to the next maker, which is what a real book does with an empty one.
        int256 virtualQuote = int256(quoteBal) + _peg[key].offset;
        if (baseBal == 0 || virtualQuote <= 0) revert NotCentred(key);

        updatedSwap = swap;
        if (bidSide) {
            updatedSwap.balanceOut = uint256(virtualQuote);
        } else {
            updatedSwap.balanceIn = uint256(virtualQuote);
        }
        return (nextPC, 0, updatedSwap);
    }

    /// @dev Read the oracle, read the maker's two legs, and write the offset that puts the curve's
    ///      marginal price on the first using the second.
    function _repeg(bytes32 key, Cfg memory cfg) private {
        uint64 px = _oracle(cfg.perpIndex);
        (uint256 baseBal, uint256 quoteBal) =
            IAqua(cfg.aqua).safeBalances(cfg.maker, cfg.swapVM, cfg.strategyHash, cfg.base, cfg.quote);

        int256 offset =
            int256(baseBal * uint256(px) * cfg.pxNum / cfg.pxDen) - int256(quoteBal);
        _peg[key] = Peg({ px: px, at: uint64(block.timestamp), offset: offset });
        emit Repegged(key, px, uint64(block.timestamp), offset);
    }

    /// @dev The oracle word, and nothing else off the book. That is the point of this maker: it
    ///      has one number, so it cannot tell that mark has walked away from it, and it quotes the
    ///      same price into a dislocation as into a quiet afternoon.
    function _oracle(uint32 perpIndex) private view returns (uint64) {
        Book memory book = READER.read(perpIndex);
        if (book.oracle == 0) revert EmptyBook(perpIndex);
        return book.oracle;
    }

    /// @dev True when the taker is selling base, which is the maker buying it: the bid side.
    function _side(Cfg memory cfg, address tokenIn, address tokenOut) private pure returns (bool) {
        if (tokenIn == cfg.base && tokenOut == cfg.quote) return true;
        if (tokenIn == cfg.quote && tokenOut == cfg.base) return false;
        revert WrongPair(tokenIn, tokenOut);
    }
}
