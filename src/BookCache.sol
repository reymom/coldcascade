// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ICoreReader, Book } from "./interfaces/ICoreReader.sol";
import { HyperCore } from "./libs/HyperCore.sol";

/// @notice The fallback reader, and the book series the subgraph indexes. Anyone pokes; the
///         contract reads the precompiles itself from a normal call frame and stores the words.
///         Still trustless: lying requires lying about L1. One poke stale.
///
/// @dev It is the series, not the fallback, that turned out to be load-bearing. The precompiles
///      **ignore the block tag**: an `eth_call` to `0x080e` pinned 200 000 blocks back answers with
///      the current book (measured on 999, 2026-09-05 — `results/999_precompile_block_tag.md`).
///      They are node state, not chain state, so there is no archive read and no way to ask what
///      the book was. A markout needs the book at t+5, t+15 and t+60 minutes, so the only way that
///      quantity exists at all is for somebody to have written the words into a log while they were
///      current. That is what `poke` is for, and it is why the keeper runs it on a cadence.
contract BookCache is ICoreReader {
    event Booked(
        uint32 indexed perpIndex, uint64 bid, uint64 ask, uint64 mark, uint64 oracle, uint64 l1Block, address poker
    );

    error NeverPoked(uint32 perpIndex);

    mapping(uint32 perpIndex => Book) internal _books;
    mapping(uint32 perpIndex => uint64) public pokedAt;

    /// @notice Read the four words now and keep them, for this perp.
    /// @dev `HyperCore.book` reverts on a zero in any word, so a poke either stores a whole book or
    ///      stores nothing. A cache that could hold a partial book would hand `CoreQuote` a bid of
    ///      zero and turn an unreadable book into a quote, which is the one thing the reader
    ///      interface promises never to do.
    ///
    ///      Permissionless because there is nothing to gain: the caller chooses *when*, never
    ///      *what*, and a stale entry is visible as `pokedAt`.
    function poke(uint32 perpIndex) external {
        Book memory fresh = HyperCore.book(perpIndex);
        _books[perpIndex] = fresh;
        pokedAt[perpIndex] = uint64(block.timestamp);
        emit Booked(perpIndex, fresh.bid, fresh.ask, fresh.mark, fresh.oracle, HyperCore.l1BlockNumber(), msg.sender);
    }

    /// @notice The last poked book. Reverts rather than returning zeros for a perp never poked.
    /// @dev Staleness is not checked here. A reader cannot know what age its caller can tolerate,
    ///      and `CoreQuote` treats a book as an input it either has or does not; the age is on
    ///      `pokedAt` for whoever needs it. As `CoreQuote`'s READER this is a deployment choice made
    ///      once, not a fallback the quote can slip into.
    function read(uint32 perpIndex) external view returns (Book memory) {
        if (pokedAt[perpIndex] == 0) revert NeverPoked(perpIndex);
        return _books[perpIndex];
    }
}
