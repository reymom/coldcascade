// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IMapOracle, LiquidationMap } from "./interfaces/IMapOracle.sol";

/// @notice The only trusted write in the system. One updater, one word per perp, a timestamp.
///         A quote reading a map older than its `mapMaxAge` ignores it.
contract MapOracle is IMapOracle {
    address public immutable UPDATER;

    error NotUpdater(address caller);

    mapping(uint32 perpIndex => LiquidationMap) internal _maps;

    constructor(address updater) {
        UPDATER = updater;
    }

    /// @notice Post the forced notional sitting within 1% of mark on each side.
    /// @dev The timestamp is set here, not passed in: the quote's staleness check is only worth
    ///      anything if the clock is the chain's and not the keeper's.
    function update(uint32 perpIndex, uint128 belowNotional, uint128 aboveNotional) external {
        if (msg.sender != UPDATER) revert NotUpdater(msg.sender);
        uint64 updatedAt = uint64(block.timestamp);
        _maps[perpIndex] =
            LiquidationMap({ belowNotional: belowNotional, aboveNotional: aboveNotional, updatedAt: updatedAt });
        emit MapUpdated(perpIndex, belowNotional, aboveNotional, updatedAt);
    }

    /// @notice A perp never updated reads as (0, 0, 0), which every consumer treats as no map.
    function map(uint32 perpIndex) external view returns (LiquidationMap memory) {
        return _maps[perpIndex];
    }
}
