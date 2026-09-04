// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Deployed to testnet 998 to answer, on a real node, the one question a fork cannot:
///         does a view function reached through STATICCALL get two words back from 0x080e,
///         and how much gas does a bad index burn under a cap.
contract Probe {
    /// @notice Depth 1: this contract staticcalls the precompile.
    function direct(uint32 perpIndex) external view returns (uint64 bid, uint64 ask, uint256 gasUsed) {
        revert("todo");
    }

    /// @notice Depth 2: this contract staticcalls itself, which staticcalls the precompile.
    ///         Same shape as router -> CoreQuote -> precompile.
    function nested(uint32 perpIndex) external view returns (uint64 bid, uint64 ask, uint256 gasUsed) {
        revert("todo");
    }

    /// @notice What an invalid input costs under `gasCap`, and whether the outer frame survives it.
    function badInput(uint256 gasCap) external view returns (bool ok, uint256 gasUsed) {
        revert("todo");
    }
}
