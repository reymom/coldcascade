// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { IDeskAccount } from "./interfaces/IDeskAccount.sol";
import { Book } from "./interfaces/ICoreReader.sol";
import { DeskParams } from "./libs/DeskParams.sol";
import { DeskPrograms } from "./libs/DeskPrograms.sol";
import { Side } from "./libs/Regime.sol";

/// @title DeskAccount
/// @notice One desk, owned by one address. A minimal clone deployed by `DeskFactory.open`, which is
///         the Aqua maker: it holds the two tokens, approves Aqua once, ships
///         `XYCSwap || Extruction(CoreQuote, params)` from itself, and gives its owner four typed
///         calls — `reopen`, `close`, `withdraw`, `armHedge`.
///
/// @dev **This is not a vault.** No pooling, no shares, no third party, no fee, no upgrade, no
///      admin: an account has exactly one owner and `close()` is one call that docks the strategy
///      and sends everything home. What it costs is that the maker's tokens sit in a contract the
///      maker owns rather than in the wallet itself. What it buys is an *object* — a desk with an
///      address, which is what a name can point at, a subgraph can index, a device can be shown
///      the parameters of, and a HyperCore margin account can belong to.
///
///      The account can still commit more to a strategy than it holds. That is the maker's own
///      choice and Aqua's own behaviour — `pull` is a plain transferFrom and reverts at settlement
///      if the balance is not there. Nothing here pretends otherwise.
///
///      Parameters are immutable per strategy, because Aqua keys a strategy by the hash of its
///      bytes. A parameter change is therefore a dock and a fresh ship, which is what `reopen` is.
///      There is no other kind of parameter change and none is being hidden.
contract DeskAccount is IDeskAccount {
    using SafeERC20 for IERC20;

    /// @dev Shared by every clone: immutables live in the implementation's runtime code, which is
    ///      the code a clone delegates into.
    IAqua public immutable AQUA;
    address public immutable ROUTER;
    address public immutable CORE_QUOTE;
    address public immutable HOOKS;
    address public immutable FACTORY;

    address public owner;
    /// @notice The label this desk was opened under. The ENS subname is minted from it later; the
    ///         account does not resolve names and does not need to.
    string public label;
    /// @notice The strategy currently shipped on Aqua, or zero when the desk is closed.
    bytes32 public strategyHash;
    /// @notice How many times this account has shipped. It is the salt, so a desk can reopen with
    ///         the parameters it already had — Aqua refuses a strategy hash it has already seen,
    ///         and docking does not free the key.
    uint64 public shipCount;

    bool public hedgeArmed;
    /// @notice Ceiling on the notional of one hedge, in quote-token units. A fill above it is
    ///         hedged up to the ceiling, not skipped.
    uint64 public hedgeMaxNotional;

    DeskParams internal _params;

    event DeskShipped(bytes32 indexed strategyHash, uint256 amountBase, uint256 amountQuote, DeskParams params);
    event DeskClosed(bytes32 indexed strategyHash);
    event Withdrawn(address indexed token, uint256 amount);
    event HedgeArmed(bool armed, uint64 maxNotional);

    /// @notice What the desk would send to HyperCore for this fill: the perp, the direction, the
    ///         size in base units and what it is worth at mark, after the notional ceiling.
    /// @dev The CoreWriter action itself is not built here. Sending one needs the account to hold an
    ///      activated HyperCore account, which is a probe that has not been run — until it has, the
    ///      honest artifact is the decision, not a payload with an unverified price scale in it.
    event HedgeIntent(
        bytes32 indexed orderHash, uint32 perpIndex, bool isBuy, uint256 baseAmount, uint256 notional, uint64 mark
    );

    /// @notice Why a fill was not hedged. Every fill produces exactly one of this or `HedgeIntent`,
    ///         so "the hedge did nothing" is always a readable statement rather than a silence.
    event HedgeSkipped(bytes32 indexed orderHash, SkipReason reason);

    enum SkipReason {
        Disarmed,
        NotStressSide,
        NoNotional
    }

    error OnlyOwner(address caller);
    error OnlyFactory(address caller);
    error OnlyHooks(address caller);
    error AlreadyInitialized();
    error NotOpen();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner(msg.sender);
        _;
    }

    constructor(IAqua aqua, address router, address coreQuote, address hooks, address factory) {
        AQUA = aqua;
        ROUTER = router;
        CORE_QUOTE = coreQuote;
        HOOKS = hooks;
        FACTORY = factory;
    }

    /// @notice Called once by the factory, in the transaction that deploys the clone and funds it.
    /// @dev The implementation itself is never initialized: only the factory may call this, and the
    ///      factory only ever calls its own clones.
    function initialize(
        address owner_,
        string calldata label_,
        DeskParams calldata p,
        uint256 amountBase,
        uint256 amountQuote
    ) external returns (bytes32) {
        if (msg.sender != FACTORY) revert OnlyFactory(msg.sender);
        if (owner != address(0)) revert AlreadyInitialized();
        owner = owner_;
        label = label_;
        return _ship(p, amountBase, amountQuote);
    }

    // ---- the four typed calls a device is asked to confirm ----

    /// @notice Dock the current strategy and ship a new one. **This is what a parameter change is.**
    /// @dev The two amounts are what the new strategy commits to Aqua, not a transfer: tokens
    ///      already in the account stay in it. Send more first, or `withdraw` what is not wanted.
    function reopen(DeskParams calldata p, uint256 amountBase, uint256 amountQuote)
        external
        onlyOwner
        returns (bytes32)
    {
        if (strategyHash != bytes32(0)) _dock();
        return _ship(p, amountBase, amountQuote);
    }

    /// @notice Dock the strategy and send both tokens home. One call, no unwind, no queue.
    function close() external onlyOwner {
        bytes32 closed = _dock();
        _sweep(_params.base);
        _sweep(_params.quote);
        emit DeskClosed(closed);
    }

    /// @notice Take tokens out of the account. Allowed while a strategy is open, which can leave
    ///         the strategy committing more than the account holds — Aqua's `pull` then reverts at
    ///         settlement and the subgraph flags the desk unbacked. The maker's call to make.
    function withdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner, amount);
        emit Withdrawn(token, amount);
    }

    /// @notice Arm or disarm the hedge, and set the per-fill notional ceiling in quote units.
    function armHedge(bool armed, uint64 maxNotional) external onlyOwner {
        hedgeArmed = armed;
        hedgeMaxNotional = maxNotional;
        emit HedgeArmed(armed, maxNotional);
    }

    // ---- the fill callback ----

    /// @inheritdoc IDeskAccount
    /// @dev Runs inside the taker's swap, after settlement, under a gas cap the hook sets, wrapped
    ///      so that anything it does is invisible to the fill. It hedges the side the desk was
    ///      *absorbing* on: bought base under a bid lean means the desk is long and the perp leg
    ///      sells, and the mirror on the ask. A quiet fill is not a hedge — the desk sitting outside
    ///      L1 and getting lifted is inventory it wanted.
    function onFill(
        bytes32 orderHash,
        address tokenIn,
        address,
        uint256 amountIn,
        uint256 amountOut,
        Book calldata book,
        Side lean
    ) external {
        if (msg.sender != HOOKS) revert OnlyHooks(msg.sender);
        if (!hedgeArmed) {
            emit HedgeSkipped(orderHash, SkipReason.Disarmed);
            return;
        }

        DeskParams memory p = _params;
        bool boughtBase = tokenIn == p.base;
        if (boughtBase ? lean != Side.Bid : lean != Side.Ask) {
            emit HedgeSkipped(orderHash, SkipReason.NotStressSide);
            return;
        }

        uint256 baseAmount = boughtBase ? amountIn : amountOut;
        uint256 notional = baseAmount * uint256(book.mark) * p.pxNum / p.pxDen;
        if (notional == 0) {
            emit HedgeSkipped(orderHash, SkipReason.NoNotional);
            return;
        }

        // A fill larger than the ceiling is hedged up to the ceiling. Partial cover beats none, and
        // the ceiling is what the owner signed for.
        if (notional > hedgeMaxNotional) {
            baseAmount = Math.mulDiv(baseAmount, hedgeMaxNotional, notional);
            notional = hedgeMaxNotional;
        }

        // Long base wants a short perp, and the mirror. No sign is hard-coded anywhere else.
        emit HedgeIntent(orderHash, p.perpIndex, !boughtBase, baseAmount, notional, book.mark);
    }

    // ---- views ----

    function params() external view returns (DeskParams memory) {
        return _params;
    }

    /// @notice The order a taker swaps against, rebuilt from the account's own state.
    /// @dev A page reconstructing this by hand is F4 waiting to happen. It is one `eth_call`.
    function order() external view returns (ISwapVM.Order memory) {
        DeskParams memory p = _params;
        return DeskPrograms.order(address(this), HOOKS, DeskPrograms.deskWithSalt(CORE_QUOTE, p, _salt(shipCount)), p);
    }

    function isOpen() external view returns (bool) {
        return strategyHash != bytes32(0);
    }

    // ---- internals ----

    function _ship(DeskParams calldata p, uint256 amountBase, uint256 amountQuote) private returns (bytes32 shipped) {
        _params = p;
        uint64 count = shipCount + 1;
        shipCount = count;

        _approveAqua(p.base);
        _approveAqua(p.quote);

        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (amountBase, amountQuote);

        ISwapVM.Order memory o =
            DeskPrograms.order(address(this), HOOKS, DeskPrograms.deskWithSalt(CORE_QUOTE, p, _salt(count)), p);
        shipped = AQUA.ship(ROUTER, DeskPrograms.strategyBytes(o), DeskPrograms.tokens(p), amounts);
        strategyHash = shipped;

        emit DeskShipped(shipped, amountBase, amountQuote, p);
    }

    function _dock() private returns (bytes32 docked) {
        docked = strategyHash;
        if (docked == bytes32(0)) revert NotOpen();
        strategyHash = bytes32(0);
        AQUA.dock(ROUTER, docked, DeskPrograms.tokens(_params));
    }

    function _sweep(address token) private {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return;
        IERC20(token).safeTransfer(owner, balance);
        emit Withdrawn(token, balance);
    }

    /// @dev `forceApprove` because a token that requires the allowance be zeroed first is a token
    ///      the desk should still be able to trade.
    function _approveAqua(address token) private {
        if (IERC20(token).allowance(address(this), address(AQUA)) != type(uint256).max) {
            IERC20(token).forceApprove(address(AQUA), type(uint256).max);
        }
    }

    /// @dev Unique per account and per ship, so the same parameters can be shipped again.
    function _salt(uint64 count) private view returns (bytes32) {
        return keccak256(abi.encode(address(this), count));
    }
}
