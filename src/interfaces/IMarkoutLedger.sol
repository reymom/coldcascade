// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Where the keeper writes what it computed from indexed fills: the markout of a fill
///         at a horizon, in bps. Informational; the quote never reads it.
interface IMarkoutLedger {
    event Markout(bytes32 indexed orderHash, bytes32 indexed fillId, uint8 horizonMinutes, int256 bps, uint64 postedAt);

    function post(bytes32 orderHash, bytes32 fillId, uint8 horizonMinutes, int256 bps) external;
}
