// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DeskTest } from "./base/DeskTest.sol";
import { BookCache } from "../src/BookCache.sol";
import { Book } from "../src/interfaces/ICoreReader.sol";
import { HyperCore } from "../src/libs/HyperCore.sol";
import { HyperCoreMock } from "./mocks/HyperCoreMock.sol";

/// @notice The book series, which is the only history of the book there is: the precompiles ignore
///         the block tag, so nothing can be asked what the book was — see
///         `results/999_live_quote.md`. What is worth testing is that a poke either stores a whole
///         book or stores nothing, and that a perp nobody poked says so instead of reading as zero.
contract BookCacheTest is DeskTest {
    /// @dev The caller chooses when, never what, so there is nothing to gate.
    function test_poke_isPermissionless() public {
        address stranger = vm.addr(0xB0B);
        vm.prank(stranger);
        bookCache.poke(BTC);

        Book memory cached = bookCache.read(BTC);
        assertEq(cached.bid, QUIET_BID);
        assertEq(cached.ask, QUIET_ASK);
        assertEq(bookCache.pokedAt(BTC), uint64(block.timestamp));
    }

    function test_poke_emitsBooked() public {
        HyperCoreMock(payable(HyperCore.L1_BLOCK_NUMBER)).setL1Block(777_000);

        vm.expectEmit(true, false, false, true, address(bookCache));
        emit BookCache.Booked(BTC, QUIET_BID, QUIET_ASK, QUIET_MARK, QUIET_ORACLE, 777_000, address(this));
        bookCache.poke(BTC);
    }

    function test_read_matchesLastPoke() public {
        bookCache.poke(BTC);
        setBook(QUIET_BID + 500, QUIET_ASK + 500, QUIET_MARK + 500, QUIET_ORACLE + 500);

        Book memory stale = bookCache.read(BTC);
        assertEq(stale.bid, QUIET_BID, "one poke stale, by construction");

        vm.warp(block.timestamp + 60);
        bookCache.poke(BTC);
        assertEq(bookCache.read(BTC).bid, QUIET_BID + 500);
        assertEq(bookCache.pokedAt(BTC), uint64(block.timestamp), "and the age moved with it");
    }

    function test_read_beforeAnyPoke_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(BookCache.NeverPoked.selector, uint32(3)));
        bookCache.read(3);
    }

    /// @dev A cache that could hold half a book would hand CoreQuote a bid of zero, which is the
    ///      one thing the reader interface promises never to do. An empty book is not cached at all.
    function test_poke_emptyBookIsNotCached() public {
        setBookAt(3, 0, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(HyperCore.EmptyBook.selector, uint32(3)));
        bookCache.poke(3);

        vm.expectRevert(abi.encodeWithSelector(BookCache.NeverPoked.selector, uint32(3)));
        bookCache.read(3);
    }

    /// @dev It is a reader, so a desk can be shipped against it. The point of the fallback.
    function test_cache_canPriceADesk() public {
        bookCache.poke(BTC);
        assertEq(bookCache.read(BTC).mark, precompiles.read(BTC).mark, "same words, one poke apart");
    }
}
