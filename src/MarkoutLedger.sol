// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IMarkoutLedger } from "./interfaces/IMarkoutLedger.sol";

/// @notice The keeper reads fills from the Substreams stream, joins them to later books, and
///         posts the markout here. Read Graph, decide, write chain; then Graph indexes the
///         decision, which is how the keeper knows what it has already said.
contract MarkoutLedger is IMarkoutLedger {
    address public immutable POSTER;

    error NotPoster(address caller);

    constructor(address poster) {
        POSTER = poster;
    }

    /// @notice Record what a fill was worth at a horizon, in bps.
    /// @dev A log and nothing else. Storage would only be worth paying for if a contract read it
    ///      back, and none does: the quote does not consult markouts, and the page and the keeper
    ///      both read them through the stream. What the chain is being used for here is the one
    ///      thing a log gives that an API does not — the keeper cannot restate a number it already
    ///      posted, and the timestamp is the chain's, not the keeper's.
    function post(bytes32 orderHash, bytes32 fillId, uint8 horizonMinutes, int256 bps) external {
        if (msg.sender != POSTER) revert NotPoster(msg.sender);
        emit Markout(orderHash, fillId, horizonMinutes, bps, uint64(block.timestamp));
    }
}
