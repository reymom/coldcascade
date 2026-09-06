// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ICoreWriter } from "./interfaces/ICoreWriter.sol";

/// @notice The one question a fork, a testnet and a doc cannot answer: can a HyperCore account that
///         belongs to a *contract*, and that was created by an incoming transfer rather than by a
///         signature, emit CoreWriter actions?
///
/// @dev It matters because `DeskAccount.cover()` currently stops at an event. Turning that event
///      into an order is one `sendRawAction`, and the only thing standing between the two is
///      whether HyperCore will accept an action from an address that has never signed anything.
///
///      Two published sources disagree, which is why this is a probe and not a paragraph.
///      Hyperliquid's activation-fee page says the fee is charged on *"the first transaction which
///      has the new account as destination address"* — i.e. the incoming transfer pays it, and the
///      account is live afterwards. Circle's CCTP-on-HyperCore page says the opposite: the fee is
///      *"earmarked at the account level and charged on the user's first outbound action"*, and
///      until then *"the account is considered unactivated and cannot perform CoreWriter
///      actions"*. For a contract that second reading is a dead end, because a contract's only
///      outbound action *is* a CoreWriter action.
///
///      The probe is deliberately not a `DeskAccount`. A clone carries an Aqua strategy, two token
///      balances and an owner; none of that changes the answer, and all of it adds ways for the
///      run to fail for a reason that is not the question. What is under test is an address with
///      code and no signing key.
///
///      **This contract can only be emptied by an action it may not be allowed to send.** If
///      HyperCore refuses, whatever was transferred in is stranded at this address forever. Fund it
///      with the smallest amount that can still place a legal order and no more.
contract CoreProbe {
    ICoreWriter internal constant CORE_WRITER = ICoreWriter(0x3333333333333333333333333333333333333333);

    address internal constant POSITION = 0x0000000000000000000000000000000000000800;
    address internal constant SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address internal constant WITHDRAWABLE = 0x0000000000000000000000000000000000000803;
    address internal constant CORE_USER_EXISTS = 0x0000000000000000000000000000000000000810;

    /// @dev Action ids, from the CoreWriter table. `sendRawAction` takes the version byte, then the
    ///      id big-endian in three bytes, then the ABI-encoded payload.
    uint8 internal constant VERSION = 0x01;
    uint24 internal constant LIMIT_ORDER = 1;
    uint24 internal constant SPOT_SEND = 6;
    uint24 internal constant USD_CLASS_TRANSFER = 7;

    /// @dev `3` is IOC. The other values are not used here and are not guessed at.
    uint8 internal constant TIF_IOC = 3;

    address public immutable OWNER;

    /// @notice The bytes handed to CoreWriter, kept so a run can be reconstructed from a log rather
    ///         than from a shell history. The EVM receipt says nothing about what HyperCore did with
    ///         them — that is read back through the precompiles, not inferred from a status of 1.
    event Action(uint24 indexed actionId, uint128 indexed cloid, bytes data);

    error OnlyOwner(address caller);

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert OnlyOwner(msg.sender);
        _;
    }

    constructor() {
        OWNER = msg.sender;
    }

    // ---- the probe ----

    /// @notice One IOC on `asset`, priced to cross.
    /// @param asset The perp index on dex 0. BTC is 0.
    /// @param isBuy Direction.
    /// @param limitPx `1e8 * human price`. For an IOC this is the worst acceptable price, not a
    ///        resting quote: cross the book with it.
    /// @param sz `1e8 * human size`. HyperCore rounds to `szDecimals`, so this must be a multiple
    ///        of `10 ** (8 - szDecimals)` or the remainder is silently dropped.
    /// @param cloid The client order id. `DeskAccount.coverCount` becomes this, which is what makes
    ///        an order on L1 traceable back to the `cover()` that decided it.
    function order(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, uint128 cloid) external onlyOwner {
        _send(LIMIT_ORDER, cloid, abi.encode(asset, isBuy, limitPx, sz, false, TIF_IOC, cloid));
    }

    /// @notice Move USDC between this account's perp and spot balances. Step one of the exit; there
    ///         is no CoreWriter action that sends USDC straight out of a perp balance.
    /// @param ntl The amount, in whatever scale this action takes. **`[UNVERIFIED]`** — the
    ///        published table gives the type and not the units, and no primary source read on
    ///        2026-09-06 states them. It is read back off `status()` after the first call rather
    ///        than assumed: send a round number, see which balance moved by how much.
    function usdClassTransfer(uint64 ntl, bool toPerp) external onlyOwner {
        _send(USD_CLASS_TRANSFER, 0, abi.encode(ntl, toPerp));
    }

    /// @notice Send a spot token out of this account. Step two of the exit, and the confirmation
    ///         that costs nothing extra: getting the funds back out is itself an action HyperCore
    ///         had to accept from an address that has never signed.
    /// @param token The Core spot token index. USDC is 0.
    /// @param amount In the token's Core `weiDecimals`, which for USDC is 8 — the same scale
    ///        `status()` reports `spotUsdc` in, so the two can be checked against each other.
    function spotSend(address destination, uint64 token, uint64 amount) external onlyOwner {
        _send(SPOT_SEND, 0, abi.encode(destination, token, amount));
    }

    /// @notice Anything the typed calls above do not cover, encoded by hand.
    function raw(uint24 actionId, bytes calldata payload) external onlyOwner {
        _send(actionId, 0, payload);
    }

    // ---- what actually happened, read from HyperCore ----

    /// @notice The whole answer in one `eth_call`. A transaction that sent an action HyperCore threw
    ///         away has status 1 and moves nothing here.
    /// @param asset The perp index to report a position on.
    /// @return exists `0x0810`. True once the account is on HyperCore at all — which is not the same
    ///         as activated, and is exactly the gap this probe exists to measure.
    /// @return spotUsdc `0x0801`, token 0, 8 decimals.
    /// @return perpUsdc `0x0803`, 8 decimals. What the deposit actually landed as.
    /// @return szi `0x0800`, signed, in units of `10 ** -szDecimals`. **Non-zero here is the pass.**
    /// @return leverage `0x0800`. 20 on an account that has never set it.
    function status(uint32 asset)
        external
        view
        returns (bool exists, uint64 spotUsdc, uint64 perpUsdc, int64 szi, uint32 leverage)
    {
        address self = address(this);
        exists = abi.decode(_read(CORE_USER_EXISTS, abi.encode(self)), (bool));
        spotUsdc = abi.decode(_read(SPOT_BALANCE, abi.encode(self, uint64(0))), (uint64));
        perpUsdc = abi.decode(_read(WITHDRAWABLE, abi.encode(self)), (uint64));
        (szi,,, leverage,) =
            abi.decode(_read(POSITION, abi.encode(self, uint16(asset))), (int64, uint64, int64, uint32, bool));
    }

    // ---- internals ----

    function _send(uint24 actionId, uint128 cloid, bytes memory payload) private {
        bytes memory data = abi.encodePacked(VERSION, actionId, payload);
        CORE_WRITER.sendRawAction(data);
        emit Action(actionId, cloid, data);
    }

    /// @dev Uncapped on purpose. This contract is thrown away after the probe and a read that runs
    ///      out of gas would be indistinguishable from a read that says no.
    function _read(address precompile, bytes memory input) private view returns (bytes memory ret) {
        bool ok;
        (ok, ret) = precompile.staticcall(input);
        require(ok && ret.length != 0, "precompile");
    }
}
