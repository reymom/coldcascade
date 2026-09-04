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

    function update(uint32 perpIndex, uint128 belowNotional, uint128 aboveNotional) external {
        revert("todo");
    }

    function map(uint32 perpIndex) external view returns (LiquidationMap memory) {
        revert("todo");
    }
}
