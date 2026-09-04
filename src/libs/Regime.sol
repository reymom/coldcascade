// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Book } from "../interfaces/ICoreReader.sol";
import { LiquidationMap } from "../interfaces/IMapOracle.sol";
import { DeskParams } from "./DeskParams.sol";

/// @notice Which side of the desk leans in. Bid: the maker buys base from forced sellers.
enum Side {
    None,
    Bid,
    Ask
}

struct Regime {
    Side lean;
    int256 dislocationBps;    // (oracle - mark) * 1e4 / oracle; positive means the book is below oracle
    uint128 mapBelow;
    uint128 mapAbove;
    bool mapFresh;
}

/// @notice A pure function of the book, the map and the maker's parameters. No storage, no sign.
library RegimeLib {
    function dislocationBps(Book memory book) internal pure returns (int256) {
        revert("todo");
    }

    /// @dev A stale or absent map is (0, 0, false) and can only ever remove a lean, never add one.
    function classify(Book memory book, LiquidationMap memory map, DeskParams memory p, uint256 nowTs)
        internal
        pure
        returns (Regime memory)
    {
        revert("todo");
    }
}
