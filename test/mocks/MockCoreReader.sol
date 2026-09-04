// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ICoreReader, Book } from "../../src/interfaces/ICoreReader.sol";

/// @notice A reader whose book the test sets. For CoreQuote tests that do not care where the book
///         comes from.
contract MockCoreReader is ICoreReader {
    mapping(uint32 perpIndex => Book) internal _books;

    function set(uint32 perpIndex, uint64 bid, uint64 ask, uint64 mark, uint64 oracle) external {
        _books[perpIndex] = Book({ bid: bid, ask: ask, mark: mark, oracle: oracle });
    }

    function read(uint32 perpIndex) external view returns (Book memory) {
        return _books[perpIndex];
    }
}
