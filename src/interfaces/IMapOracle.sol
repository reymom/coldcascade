// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Forced notional sitting within 1% of mark on each side: what the margin engine
///         will dump (below) or buy (above) if mark keeps walking. Reconstructed off-chain.
struct LiquidationMap {
    uint128 belowNotional;
    uint128 aboveNotional;
    uint64 updatedAt;
}

/// @notice The one input the desk takes on trust. A quote that cannot see a fresh map
///         behaves as if there were none; staleness can never cause a lean.
interface IMapOracle {
    event MapUpdated(uint32 indexed perpIndex, uint128 belowNotional, uint128 aboveNotional, uint64 updatedAt);

    function map(uint32 perpIndex) external view returns (LiquidationMap memory);
}
