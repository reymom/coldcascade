// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { ICoreWriter } from "./interfaces/ICoreWriter.sol";
import { DeskParams } from "./libs/DeskParams.sol";
import { DeskPrograms } from "./libs/DeskPrograms.sol";
import { HedgeOrder, Plan, PlanInputs, SkipReason } from "./libs/HedgeOrder.sol";

/// @title DeskAccount
/// @notice One desk, owned by one address. A minimal clone deployed by `DeskFactory.open`, which is
///         the Aqua maker: it holds the two tokens, approves Aqua once, ships
///         `XYCSwap || Extruction(CoreQuote, params)` from itself, and gives its owner four typed
///         calls — `reopen`, `close`, `withdraw`, `armHedge` — plus the two that move its margin
///         on HyperCore, `marginTransfer` and `marginHome`.
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
contract DeskAccount {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;

    /// @dev Hyperliquid's system contract. An action is the version byte, the action id big-endian
    ///      in three bytes, then the ABI-encoded payload. Verified on 999, 2026-09-06, by sending
    ///      one from a contract that had never signed anything: see `cover`.
    ICoreWriter internal constant CORE_WRITER = ICoreWriter(0x3333333333333333333333333333333333333333);
    uint8 private constant ACTION_VERSION = 0x01;
    uint24 private constant ACTION_LIMIT_ORDER = 1;
    uint24 private constant ACTION_SPOT_SEND = 6;
    uint24 private constant ACTION_USD_CLASS_TRANSFER = 7;
    /// @dev The Core spot token index of USDC, which is the only asset a perp account is margined
    ///      in and therefore the only one this contract needs to name.
    uint64 private constant CORE_USDC = 0;
    /// @dev Time-in-force 3. The desk wants the hedge on now or not at all: a resting order would
    ///      leave the account believing it is covered while the book walks away from it.
    uint8 private constant TIF_IOC = 3;


    /// @dev Shared by every clone: immutables live in the implementation's runtime code, which is
    ///      the code a clone delegates into.
    IAqua public immutable AQUA;
    address public immutable ROUTER;
    address public immutable CORE_QUOTE;
    address public immutable HOOKS;

    address public owner;
    /// @notice The label this desk was opened under. The ENS subname is minted from it later; the
    ///         account does not resolve names and does not need to.
    string public label;
    /// @notice The strategy currently shipped on Aqua, or zero when the desk is closed.
    bytes32 public strategyHash;
    /// @notice How many times `cover` has run. It is the intent's id, and on Friday the CoreWriter
    ///         client order id, so a sent action can be matched to the decision that made it.
    uint64 public coverCount;
    /// @notice How many times this account has shipped. It is the salt, so a desk can reopen with
    ///         the parameters it already had — Aqua refuses a strategy hash it has already seen,
    ///         and docking does not free the key.
    uint64 public shipCount;

    bool public hedgeArmed;
    /// @notice Ceiling on the notional of one cover, in quote-token units. An exposure above it is
    ///         covered up to the ceiling and the remainder is left for the next call, not dropped.
    uint64 public hedgeMaxNotional;
    /// @notice How far through the book one cover may reach for its fill, in basis points.
    /// @dev The IOC's limit price, and the second half of the authorisation. A hedge that does not
    ///      cross is a hedge that silently does nothing, so the desk needs *some* room; how much is
    ///      the owner's to say and not a constant in here. Zero means the touch and nothing beyond
    ///      it. The order fills at the book, not at this price — it is a backstop, not a target.
    uint16 public hedgeMaxSlippageBps;
    /// @notice Who may call `cover` besides the owner. Zero means the owner alone.
    /// @dev The split PRODUCT-V2 asks for: the owner authorises the ceiling on a device, and a
    ///      scoped automation key fires within it. The operator can never move funds -- `cover`
    ///      transfers nothing and every other call is owner-only.
    address public hedgeOperator;

    /// @notice The base balance at which this desk considers itself square.
    ///
    /// @dev **This is a declaration, not a measurement, and that is the whole distinction.** It is
    ///      the inventory the owner chose to fund the desk with, so it is written exactly where the
    ///      owner says so — `initialize`, `reopen` on a pair change, `withdraw`, `close` — and by
    ///      nothing else. `cover` never touches it.
    ///
    ///      The distinction matters because the obvious alternative is a counter that `cover`
    ///      advances each time it sends — a *belief* about what HyperCore did, held by a contract
    ///      that cannot see a fill. The exchange drops an order it does not like without failing
    ///      the EVM transaction that carried it, so that counter drifts silently and compounds,
    ///      and no call anywhere would notice. There is no such variable here: what a cover needs
    ///      to know it reads. See `cover`.
    uint256 public squareBase;

    DeskParams internal _params;

    event DeskShipped(bytes32 indexed strategyHash, uint256 amountBase, uint256 amountQuote, DeskParams params);
    event DeskClosed(bytes32 indexed strategyHash);
    event Withdrawn(address indexed token, uint256 amount);
    event HedgeArmed(bool armed, uint64 maxNotional, address operator, uint16 maxSlippageBps);

    /// @notice What the desk decided to cover: the perp, the direction, the size in base units and
    ///         what it is worth at mark, after the ceiling and after the lot grid.
    /// @dev The decision, in the desk's own units. `HedgeSent` is the order that came out of it.
    ///      Both are emitted for the same cover, because they can differ — the size here is what
    ///      survives rounding to `szDecimals`, and reconciling the two is how the subgraph shows a
    ///      desk that asked for more than the exchange's grid could express.
    event HedgeIntent(
        uint64 indexed coverId, uint32 perpIndex, bool isBuy, uint256 baseAmount, uint256 notional, uint64 mark
    );

    /// @notice The order actually handed to CoreWriter, in the exchange's own units.
    /// @dev **A receipt for this is not a fill.** The EVM transaction succeeds whether or not
    ///      HyperCore accepts the action, and the action itself is applied a few seconds later; the
    ///      only proof of a fill is the account's position, which `0x0800` returns and which the
    ///      keeper and the console read. What this event proves is what was sent, and `cloid`
    ///      carries `coverId` so an order on L1 can be matched to the `cover` that decided it.
    event HedgeSent(uint64 indexed coverId, uint32 perpIndex, bool isBuy, uint64 limitPx, uint64 sz);

    /// @dev As with `HedgeSent`, a receipt is not an effect: what HyperCore did with either action
    ///      is read at `0x0801` and `0x0803`, which report the same balance in different scales.
    event MarginMoved(uint64 ntl, bool toPerp);
    event MarginSentHome(address indexed destination, uint64 amount);

    /// @notice A cover that decided to do nothing. Emitted rather than reverted, because a keeper on
    ///         a cadence hits the square case constantly and that is not an error.
    event HedgeSkipped(uint64 indexed coverId, SkipReason reason);

    error OnlyOwner(address caller);
    error OnlyCoverCaller(address caller);
    error AlreadyInitialized();
    error NotOpen();
    error HedgeDisarmed();
    error SlippageOutOfRange(uint16 bps);

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner(msg.sender);
        _;
    }

    modifier onlyCoverCaller() {
        if (msg.sender != owner && (hedgeOperator == address(0) || msg.sender != hedgeOperator)) {
            revert OnlyCoverCaller(msg.sender);
        }
        _;
    }

    /// @dev The implementation is the code a clone delegates into and is never itself a desk, so
    ///      it is given an owner here. Clone storage starts blank, so a clone reads `owner == 0` and
    ///      initializes exactly once; the implementation reads its own address and never can.
    ///
    ///      That check replaces an `onlyFactory` one, and the reason is the block: HyperEVM's small
    ///      blocks cap at 3 000 000 gas, and a factory that deployed this contract inside its own
    ///      constructor could not fit in one. Deploying the implementation first means the factory
    ///      cannot be its own constructor argument, so the guard has to be state and not identity.
    ///      Nothing is lost — a clone is created and initialized in the same transaction, so there
    ///      is no window to initialize one that was not, and a clone somebody else deploys and
    ///      funds is simply their own desk.
    constructor(IAqua aqua, address router, address coreQuote, address hooks) {
        AQUA = aqua;
        ROUTER = router;
        CORE_QUOTE = coreQuote;
        HOOKS = hooks;
        owner = address(this);
    }

    /// @notice Called once, in the transaction that deploys the clone and funds it.
    /// @dev Whoever calls it first owns the desk, which in practice is always `DeskFactory.open` in
    ///      the same transaction as the clone. The implementation cannot be reached: its constructor
    ///      already set an owner.
    function initialize(
        address owner_,
        string calldata label_,
        DeskParams calldata p,
        uint256 amountBase,
        uint256 amountQuote
    ) external returns (bytes32) {
        if (owner != address(0)) revert AlreadyInitialized();
        owner = owner_;
        label = label_;
        // Whatever the desk is funded with is inventory its owner chose, not exposure it was
        // pushed into. It opens square, and everything it accumulates after this is coverable.
        squareBase = IERC20(p.base).balanceOf(address(this));
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
        // A parameter change is not a position change, so the covered mark stands -- unless the
        // pair itself moved, in which case the old mark is denominated in a token this desk no
        // longer trades and the new base starts square.
        if (p.base != _params.base) squareBase = IERC20(p.base).balanceOf(address(this));
        return _ship(p, amountBase, amountQuote);
    }

    /// @notice Dock the strategy and send both tokens home. One call, no unwind, no queue.
    function close() external onlyOwner {
        bytes32 closed = _dock();
        _sweep(_params.base);
        _sweep(_params.quote);
        squareBase = 0;
        emit DeskClosed(closed);
    }

    /// @notice Take tokens out of the account. Allowed while a strategy is open, which can leave
    ///         the strategy committing more than the account holds — Aqua's `pull` then reverts at
    ///         settlement and the subgraph flags the desk unbacked. The maker's call to make.
    function withdraw(address token, uint256 amount) external onlyOwner {
        // `squareBase` is the level at which this desk is square. Taking base out lowers it by the
        // same amount, so a withdrawal leaves the uncovered delta exactly where it was rather than
        // reading as a new short the next cover would go and hedge.
        if (token == _params.base) {
            uint256 covered = squareBase;
            squareBase = amount < covered ? covered - amount : 0;
        }
        IERC20(token).safeTransfer(owner, amount);
        emit Withdrawn(token, amount);
    }

    /// @notice Arm or disarm cover, set the per-call notional ceiling in quote units, name who may
    ///         fire it besides the owner, and bound how far through the book one cover may reach.
    /// @dev One signature carries the whole authorisation, which is what a device should be asked
    ///      to render: *cover armed, at most $5 000 a call, within 30 bps, fired by 0x…*. The
    ///      operator spends the desk's margin within those two bounds and can do nothing else.
    function armHedge(bool armed, uint64 maxNotional, address operator, uint16 maxSlippageBps) external onlyOwner {
        if (maxSlippageBps >= BPS) revert SlippageOutOfRange(maxSlippageBps);
        hedgeArmed = armed;
        hedgeMaxNotional = maxNotional;
        hedgeOperator = operator;
        hedgeMaxSlippageBps = maxSlippageBps;
        emit HedgeArmed(armed, maxNotional, operator, maxSlippageBps);
    }

    /// @notice Move the desk's USDC between its HyperCore spot and perp balances.
    /// @param ntl The amount, in `1e6` — the action's own scale, which is not the `1e8` the order
    ///        fields use and not the `1e8` `0x0801` reports spot in. Verified on 999 on 2026-09-06
    ///        by moving 1 USDC each way and reading both sides.
    /// @param toPerp True to margin the desk, false to take the margin back.
    ///
    /// @dev **Margin has to be able to arrive and to leave, and neither happens by itself.** A
    ///      transfer into this address from HyperCore lands in *spot*, and a perp order is
    ///      margined from *perps*, so without this call a funded desk cannot trade and a desk that
    ///      can trade cannot be emptied. `cover` sends orders and nothing else.
    ///
    ///      Owner only, and deliberately not the operator's: the operator spends margin within the
    ///      owner's ceiling and can never move it.
    function marginTransfer(uint64 ntl, bool toPerp) external onlyOwner {
        _action(ACTION_USD_CLASS_TRANSFER, abi.encode(ntl, toPerp));
        emit MarginMoved(ntl, toPerp);
    }

    /// @notice Send the desk's HyperCore spot USDC to its owner.
    /// @param amount In USDC's Core `weiDecimals`, which is **8** — the scale `0x0801` reports and
    ///        not the `1e6` `marginTransfer` takes.
    ///
    /// @dev The last leg of the way out, and the reason `close()` is still one call that returns
    ///      everything: `close` sends the *tokens* home, an open perp comes home through `cover`,
    ///      and the margin behind it through `marginTransfer(n, false)` and then this. Three calls
    ///      because HyperCore has no action that does it in one, not because it is staged here.
    ///
    ///      The destination is the owner and is not a parameter. Funds leaving this contract go to
    ///      exactly one place, the same as `withdraw` and `close`, so there is no address on the
    ///      device screen that could be wrong. If the owner has no HyperCore account yet, the
    ///      protocol charges its 1 USDC activation on this transfer — the owner's cost, and worth
    ///      knowing before sending a balance smaller than that.
    function marginHome(uint64 amount) external onlyOwner {
        _action(ACTION_SPOT_SEND, abi.encode(owner, CORE_USDC, amount));
        emit MarginSentHome(owner, amount);
    }

    // ---- cover, in the desk's own transaction ----

    /// @notice Bring the desk's perp position in line with the base it is actually holding.
    /// @return covered Whether an order was sent.
    /// @return baseAmount The size sent, in base units, after the ceiling and the lot grid.
    /// @return notional What that is worth at mark, in quote units.
    ///
    /// @dev **This is not in the taker's transaction and never will be.** A hedge that cannot fail
    ///      a fill but still bills the taker for it is the taker paying for the maker's private
    ///      economics; the fill path emits `Fill` and stops. The owner or its operator pays for
    ///      cover out of its own gas, on its own schedule.
    ///
    ///      **The desk remembers nothing about what it has hedged.** Both sides of the position are
    ///      read in this call: the spot side from `balanceOf(base)` against the square level the
    ///      owner declared, the perp side from `0x0800`, which is HyperCore's own record of what
    ///      this account holds. What is left uncovered is their sum, and the order is that sum.
    ///
    ///      That is the same move `CoreQuote` makes when it prices against the book it read in the
    ///      same call rather than against a stored one, and it is here for the same reason. A
    ///      counter advanced on send would be a belief about what HyperCore did, held by a contract
    ///      that cannot see a fill; the exchange drops an order it does not like *without failing
    ///      the EVM transaction that carried it*, so such a counter walks away from the truth
    ///      silently and compounds. Deriving the exposure does not reconcile that error, it deletes
    ///      the state that could hold one. An order the exchange threw away leaves `0x0800`
    ///      unchanged, so the next cover sizes itself against the same gap and sends again.
    ///
    ///      Two consequences worth naming. The delta nets: a desk that bought and sold back covers
    ///      once, and a desk whose hedge already matches its inventory sends nothing. And `close()`
    ///      leaves the perp position standing — balance and square level both go to zero, so the
    ///      whole uncovered amount is the hedge itself, and the next cover unwinds it.
    ///
    ///      **What moved off chain, said plainly.** The in-swap version hedged only fills on the
    ///      absorbing side, because the hook handed it that fill's lean. A position delta does not
    ///      carry one, so *when* to cover is the operator's decision, under the owner's ceiling —
    ///      the keeper reads the `Fill` events and their books from the subgraph and fires. That is
    ///      a guarantee that left the contract, and it is the price of the taker not paying. The
    ///      contract still takes no view on the sign: long base sells the perp, short base buys it.
    ///
    ///      An unreadable book reverts here. In the hook it could not, because a revert would have
    ///      unwound a settled fill; in its own transaction there is nothing to protect and silence
    ///      would be worse than an error.
    function cover() external onlyCoverCaller returns (bool covered, uint256 baseAmount, uint256 notional) {
        if (!hedgeArmed) revert HedgeDisarmed();

        DeskParams memory p = _params;
        uint64 id = coverCount + 1;
        coverCount = id;

        Plan memory plan = HedgeOrder.plan(p, _inputs());
        if (!plan.ok) {
            emit HedgeSkipped(id, plan.reason);
            return (false, 0, 0);
        }

        emit HedgeIntent(id, p.perpIndex, plan.isBuy, plan.baseAmount, plan.notional, plan.mark);

        // `id` is the client order id. It is why `coverCount` is a counter and not a bool: the
        // order that lands on L1 carries the number of the decision that made it.
        _action(
            ACTION_LIMIT_ORDER, abi.encode(p.perpIndex, plan.isBuy, plan.limitPx, plan.sz, false, TIF_IOC, uint128(id))
        );
        emit HedgeSent(id, p.perpIndex, plan.isBuy, plan.limitPx, plan.sz);
        return (true, plan.baseAmount, plan.notional);
    }

    /// @notice What `cover` would do right now, without doing it. What the keeper's queue shows and
    ///         what the console draws in the hedge row.
    /// @dev The same `_plan`, so the row is the order that would be sent and not the one that was
    ///      asked for — including the cases where `cover` would decline to send anything.
    function coverPreview() external view returns (bool wouldCover, bool isBuy, uint256 baseAmount, uint256 notional) {
        if (!hedgeArmed) return (false, false, 0, 0);
        Plan memory plan = HedgeOrder.plan(_params, _inputs());
        // Zeroed when nothing would be sent, including the two walls where `_plan` has already
        // sized an amount it then declined. A caller should not have to know which fields of a
        // refusal are still meaningful; the refusal itself is what `HedgeSkipped` carries.
        if (!plan.ok) return (false, false, 0, 0);
        return (true, plan.isBuy, plan.baseAmount, plan.notional);
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

    /// @dev What the desk tells `HedgeOrder` about itself. The library is delegatecalled and could
    ///      read these slots, and deliberately does not — see `PlanInputs`.
    function _inputs() private view returns (PlanInputs memory) {
        return PlanInputs({
            desk: address(this),
            coreQuote: CORE_QUOTE,
            squareBase: squareBase,
            maxNotional: hedgeMaxNotional,
            maxSlippageBps: hedgeMaxSlippageBps
        });
    }

    /// @dev One version byte, the action id big-endian in three, then the payload. Every action
    ///      this contract sends goes through here, so the header exists once.
    function _action(uint24 actionId, bytes memory payload) private {
        CORE_WRITER.sendRawAction(abi.encodePacked(ACTION_VERSION, actionId, payload));
    }

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
