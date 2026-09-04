// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ICoreReader, Book } from "./interfaces/ICoreReader.sol";
import { HyperCore } from "./libs/HyperCore.sol";

/// @notice The fallback reader, and the book series the subgraph indexes. Anyone pokes; the
///         contract reads the precompiles itself from a normal call frame and stores the words.
///         Still trustless: lying requires lying about L1. One poke stale.
contract BookCache is ICoreReader {
    event Booked(
        uint32 indexed perpIndex, uint64 bid, uint64 ask, uint64 mark, uint64 oracle, uint64 l1Block, address poker
    );

    error NeverPoked(uint32 perpIndex);

    mapping(uint32 perpIndex => Book) internal _books;
    mapping(uint32 perpIndex => uint64) public pokedAt;

    function poke(uint32 perpIndex) external {
        revert("todo");
    }

    function read(uint32 perpIndex) external view returns (Book memory) {
        revert("todo");
    }
}
