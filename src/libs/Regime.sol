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
    int256 internal constant BPS = 10_000;

    /// @notice How far the perp book has walked from the CEX oracle, in bps of the oracle.
    /// @dev Positive means mark is below oracle: the book is being pushed down, which is what
    ///      forced selling looks like from outside. Negative is the mirror. Integer division
    ///      truncates toward zero, so a threshold comparison is met a hair late on both signs,
    ///      never early.
    function dislocationBps(Book memory book) internal pure returns (int256) {
        if (book.oracle == 0) return 0;
        int256 oracle = int256(uint256(book.oracle));
        return (oracle - int256(uint256(book.mark))) * BPS / oracle;
    }

    /// @notice Two words with two trusts. The book is read from the node every block and nobody
    ///         signs it; the map is ours, minutes old, and only ever consulted to *add* a lean.
    /// @dev A stale, absent or zero map is (0, 0, false) and leaves the book-only answer standing.
    ///      That asymmetry is the whole trust argument: the worst a broken keeper can do is take a
    ///      lean away, and a desk with no lean is a desk sitting outside L1.
    ///
    ///      `stressBps` of zero means the desk is always leaning bid. That is the maker's call to
    ///      make, not this library's; the contract takes no view on the sign.
    ///
    ///      If the map loads both sides at once, the down side wins. Fixed precedence, so the
    ///      answer is a function of the inputs and nothing else.
    function classify(Book memory book, LiquidationMap memory map, DeskParams memory p, uint256 nowTs)
        internal
        pure
        returns (Regime memory r)
    {
        r.dislocationBps = dislocationBps(book);
        r.mapBelow = map.belowNotional;
        r.mapAbove = map.aboveNotional;
        // A timestamp ahead of `nowTs` is our own updater, not staleness, so it counts as fresh.
        r.mapFresh = map.updatedAt != 0 && (nowTs <= map.updatedAt || nowTs - map.updatedAt <= p.mapMaxAge);

        int256 threshold = int256(uint256(p.stressBps));
        bool loadedBelow = r.mapFresh && r.mapBelow != 0 && r.mapBelow >= p.mapMinNotional;
        bool loadedAbove = r.mapFresh && r.mapAbove != 0 && r.mapAbove >= p.mapMinNotional;

        bool stressDown = r.dislocationBps >= threshold || loadedBelow;
        bool stressUp = r.dislocationBps <= -threshold || loadedAbove;

        r.lean = stressDown ? Side.Bid : stressUp ? Side.Ask : Side.None;
    }
}
