// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ICoreReader, Book } from "./interfaces/ICoreReader.sol";
import { HyperCore } from "./libs/HyperCore.sol";

/// @notice The trustless reader: three capped staticcalls to the node, no state, no owner.
/// @dev Chosen as CoreQuote's READER because the 998 probe showed a view target reached through
///      STATICCALL gets its two words back from 0x080e at the same cost as at depth one.
contract CorePrecompiles is ICoreReader {
    function read(uint32 perpIndex) external view returns (Book memory) {
        return HyperCore.book(perpIndex);
    }
}
