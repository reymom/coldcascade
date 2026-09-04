// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Book } from "../interfaces/ICoreReader.sol";

/// @notice Raw reads of the HyperCore precompiles. Every call is a capped staticcall with a
///         return-length check; an empty book is an error, never a zero.
/// @dev The precompiles hold no bytecode (checked on 999, 2026-09-04). They are served by the
///      node, which means a forge fork cannot reach them: tests etch HyperCoreMock at these
///      addresses instead, and the live behaviour is probed on testnet 998.
library HyperCore {
    address internal constant MARK_PX = 0x0000000000000000000000000000000000000806;
    address internal constant ORACLE_PX = 0x0000000000000000000000000000000000000807;
    address internal constant L1_BLOCK_NUMBER = 0x0000000000000000000000000000000000000809;
    address internal constant PERP_ASSET_INFO = 0x000000000000000000000000000000000000080a;
    address internal constant BBO = 0x000000000000000000000000000000000000080e;

    /// @dev Gas forwarded to a precompile frame. An invalid input burns everything forwarded,
    ///      so this is a ceiling, not an estimate. Zero until measured with Probe on 998.
    uint256 internal constant PRECOMPILE_GAS_CAP = 0; // [UNVERIFIED]

    error PrecompileCallFailed(address precompile, uint32 perpIndex);
    error EmptyBook(uint32 perpIndex);

    function markPx(uint32 perpIndex) internal view returns (uint64) {
        revert("todo");
    }

    function oraclePx(uint32 perpIndex) internal view returns (uint64) {
        revert("todo");
    }

    /// @return bid Raw L1 best bid. (0, 0) on an asset with no book — see EmptyBook.
    function bbo(uint32 perpIndex) internal view returns (uint64 bid, uint64 ask) {
        revert("todo");
    }

    function l1BlockNumber() internal view returns (uint64) {
        revert("todo");
    }

    function szDecimals(uint32 perpIndex) internal view returns (uint8) {
        revert("todo");
    }

    /// @notice All four words, or EmptyBook if any is zero.
    function book(uint32 perpIndex) internal view returns (Book memory) {
        revert("todo");
    }
}
