// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ICoreReader, Book } from "./interfaces/ICoreReader.sol";
import { HyperCore } from "./libs/HyperCore.sol";

/// @notice The trustless reader: four capped staticcalls to the node. Chosen as CoreQuote's READER
///         if the Friday probe on 998 shows a view target can reach 0x080e from a STATICCALL frame.
contract CorePrecompiles is ICoreReader {
    function read(uint32 perpIndex) external view returns (Book memory) {
        revert("todo");
    }
}
