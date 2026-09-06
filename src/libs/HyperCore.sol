// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Book } from "../interfaces/ICoreReader.sol";

/// @notice The HyperCore asset record behind 0x080a. Layout read off chain 999 (BTC, margin table
///         56, szDecimals 5, 40x, cross) and chain 998 (SOL, 10, 2, 10x, cross) on 2026-09-04.
struct PerpAssetInfo {
    string coin;
    uint32 marginTableId;
    uint8 szDecimals;
    uint8 maxLeverage;
    bool onlyIsolated;
}

/// @notice Raw reads of the HyperCore precompiles. Every call is a capped staticcall with a
///         return-length check; an empty book is an error, never a zero.
/// @dev The precompiles hold no bytecode (checked on 999, 2026-09-04). They are served by the
///      node, which means a forge fork cannot reach them: tests etch HyperCoreMock at these
///      addresses instead, and the live behaviour is probed on testnet 998.
library HyperCore {
    address internal constant POSITION = 0x0000000000000000000000000000000000000800;
    address internal constant MARK_PX = 0x0000000000000000000000000000000000000806;
    address internal constant ORACLE_PX = 0x0000000000000000000000000000000000000807;
    address internal constant L1_BLOCK_NUMBER = 0x0000000000000000000000000000000000000809;
    address internal constant PERP_ASSET_INFO = 0x000000000000000000000000000000000000080a;
    address internal constant BBO = 0x000000000000000000000000000000000000080e;

    /// @dev Gas forwarded to a precompile frame. An invalid input burns everything forwarded,
    ///      so this is a ceiling, not an estimate.
    ///
    ///      Measured on chain 998 at block 63 394 536, 2026-09-04, with src/Probe.sol: a good read
    ///      costs 3 235 (mark), 3 235 (oracle), 2 179 (L1 block), 4 291 (BBO) and 10 627
    ///      (asset info) gas. `0x0800` was measured separately on 999 on 2026-09-06 at **8 515**,
    ///      the same whether the account holds a position or has never existed — the 4 291 and
    ///      10 627 above reproduced exactly in that run, which is what makes the new number
    ///      comparable. Both a wrong-length input and an out-of-range perp index consume
    ///      every gas unit forwarded and return nothing. The cap is set at ~2.8x the most
    ///      expensive read, so a node-side cost increase does not turn a good read into a revert,
    ///      and a bad input costs the caller 30 000 gas instead of 63/64 of the frame.
    uint256 internal constant PRECOMPILE_GAS_CAP = 30_000;

    error PrecompileCallFailed(address precompile, uint32 perpIndex);
    error EmptyBook(uint32 perpIndex);

    function markPx(uint32 perpIndex) internal view returns (uint64) {
        return _word(MARK_PX, perpIndex);
    }

    function oraclePx(uint32 perpIndex) internal view returns (uint64) {
        return _word(ORACLE_PX, perpIndex);
    }

    /// @return bid Raw L1 best bid. (0, 0) on an asset with no book — see EmptyBook.
    /// @return ask Raw L1 best ask.
    function bbo(uint32 perpIndex) internal view returns (uint64 bid, uint64 ask) {
        bytes memory ret = _call(BBO, abi.encode(perpIndex), 0x40, perpIndex);
        uint256 hi;
        uint256 lo;
        assembly ("memory-safe") {
            hi := mload(add(ret, 0x20))
            lo := mload(add(ret, 0x40))
        }
        if (hi > type(uint64).max || lo > type(uint64).max) revert PrecompileCallFailed(BBO, perpIndex);
        return (uint64(hi), uint64(lo));
    }

    function l1BlockNumber() internal view returns (uint64) {
        bytes memory ret = _call(L1_BLOCK_NUMBER, "", 0x20, 0);
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        if (word > type(uint64).max) revert PrecompileCallFailed(L1_BLOCK_NUMBER, 0);
        return uint64(word);
    }

    /// @notice The lot grid an order size is rounded onto, and the exponent every price scale on
    ///         this asset is built from.
    /// @dev Read at a fixed offset rather than through `abi.decode`, and the reason is size, not
    ///      speed: `PerpAssetInfo` leads with a `string`, so decoding it pulls the whole dynamic
    ///      ABI decoder into every contract that calls this. Measured on 2026-09-06, that decoder
    ///      cost `DeskAccount` 43 713 gas of code deposit and left it **654 gas** under HyperEVM's
    ///      3 000 000 small-block ceiling — three bytes from undeployable. The raw read is the
    ///      difference between deployable and not, which is why a fixed offset is worth its risk
    ///      here and nowhere else.
    ///
    ///      The layout is the ABI encoding of the struct, verified against 0x080a on 999 for BTC
    ///      on 2026-09-06 — `[0x00] 0x20` the offset to the tuple, then the tuple's head:
    ///      `[0x20]` the offset of `coin`, `[0x40]` marginTableId, `[0x60]` **szDecimals**,
    ///      `[0x80]` maxLeverage, `[0xa0]` onlyIsolated, `[0xc0]` the string's length. Both the
    ///      leading offset and the minimum length are checked, so a record that is not this shape
    ///      is an error and never a plausible-looking wrong number.
    function szDecimals(uint32 perpIndex) internal view returns (uint8) {
        bytes memory ret = _call(PERP_ASSET_INFO, abi.encode(perpIndex), 0, perpIndex);
        uint256 head;
        uint256 value;
        assembly ("memory-safe") {
            head := mload(add(ret, 0x20))
            value := mload(add(ret, 0x80))
        }
        if (ret.length < 0xe0 || head != 0x20 || value > type(uint8).max) {
            revert PrecompileCallFailed(PERP_ASSET_INFO, perpIndex);
        }
        return uint8(value);
    }

    /// @notice The account's own perp position, in lots — signed, negative for a short.
    /// @dev **The reason a desk does not need to remember what it hedged.** HyperCore holds the
    ///      position; the desk reads it in the same call it prices from, the way `CoreQuote` reads
    ///      the book instead of trusting a stored quote. An order HyperCore rejected leaves this
    ///      unchanged, so the next cover sizes itself against the same gap and sends again.
    ///
    ///      160 bytes: `[0x00]` szi, `[0x20]` entryNtl, `[0x40]` isolatedRawUsd, `[0x60]` leverage,
    ///      `[0x80]` isIsolated. Layout read off 999 on 2026-09-06, where a desk holding
    ///      `-0.00014` BTC answered `szi -14` with `20` in the fourth word — the leverage landing
    ///      where it does is what pins the other four.
    ///
    ///      `szi` is in units of `10 ** -szDecimals`, so it is the exchange's lot and not the base
    ///      token's unit. The caller scales it; this returns what the node said.
    ///
    ///      The second argument encodes identically as `uint16` or `uint32` — both are one padded
    ///      word — so the perp index is passed through unnarrowed.
    function positionSzi(address user, uint32 perpIndex) internal view returns (int64) {
        bytes memory ret = _call(POSITION, abi.encode(user, perpIndex), 0xa0, perpIndex);
        int256 szi;
        assembly ("memory-safe") {
            szi := mload(add(ret, 0x20))
        }
        if (szi < type(int64).min || szi > type(int64).max) revert PrecompileCallFailed(POSITION, perpIndex);
        return int64(szi);
    }

    /// @notice All four words, or EmptyBook if any is zero.
    /// @dev Three precompile frames, ~10 800 gas of node work at 2026-09-04 prices.
    function book(uint32 perpIndex) internal view returns (Book memory) {
        (uint64 bid, uint64 ask) = bbo(perpIndex);
        uint64 mark = markPx(perpIndex);
        uint64 oracle = oraclePx(perpIndex);
        if (bid == 0 || ask == 0 || mark == 0 || oracle == 0) revert EmptyBook(perpIndex);
        return Book({ bid: bid, ask: ask, mark: mark, oracle: oracle });
    }

    /// @dev One capped staticcall. `expectedLength` of zero accepts any non-empty answer, which is
    ///      what a dynamically encoded record needs; anything else is checked exactly.
    function _call(address precompile, bytes memory input, uint256 expectedLength, uint32 perpIndex)
        private
        view
        returns (bytes memory ret)
    {
        bool ok;
        (ok, ret) = precompile.staticcall{ gas: PRECOMPILE_GAS_CAP }(input);
        if (!ok || ret.length == 0 || (expectedLength != 0 && ret.length != expectedLength)) {
            revert PrecompileCallFailed(precompile, perpIndex);
        }
    }

    function _word(address precompile, uint32 perpIndex) private view returns (uint64) {
        bytes memory ret = _call(precompile, abi.encode(perpIndex), 0x20, perpIndex);
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        if (word > type(uint64).max) revert PrecompileCallFailed(precompile, perpIndex);
        return uint64(word);
    }
}
