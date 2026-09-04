// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The HyperCore book as the quote sees it, in raw L1 units.
///         price = raw / 10^(6 - szDecimals). BTC has szDecimals 5, so raw / 10 is USD.
struct Book {
    uint64 bid;
    uint64 ask;
    uint64 mark;
    uint64 oracle;
}

/// @notice One read of the live book for a perp index.
/// @dev Backed by the precompiles it is trustless and current; backed by BookCache it is
///      trustless and one poke stale. Nobody signs it in either case.
interface ICoreReader {
    function read(uint32 perpIndex) external view returns (Book memory book);
}
