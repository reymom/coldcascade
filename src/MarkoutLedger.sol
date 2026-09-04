// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IMarkoutLedger } from "./interfaces/IMarkoutLedger.sol";

/// @notice The keeper reads fills from the subgraph, joins them to later books, and posts the
///         markout here. Read Graph, decide, write chain; then Graph indexes the decision.
contract MarkoutLedger is IMarkoutLedger {
    address public immutable POSTER;

    error NotPoster(address caller);

    constructor(address poster) {
        POSTER = poster;
    }

    function post(bytes32 orderHash, bytes32 fillId, uint8 horizonMinutes, int256 bps) external {
        revert("todo");
    }
}
