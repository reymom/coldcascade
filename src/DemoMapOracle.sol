// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IMapOracle, LiquidationMap } from "./interfaces/IMapOracle.sol";

/// @notice `MapOracle` with the trust taken out, deliberately. Anyone may post a liquidation map
///         here, so anyone can put a desk that points at it into a lean and watch the wedge light.
///         It exists so a visitor can operate the one input the design takes on trust, instead of
///         reading a sentence about it.
///
/// @dev **No desk holding real inventory may point at this contract**, and none does: the canonical
///      desk's `mapOracle` is `MapOracle`, whose updater is one address. A quote leaning inside the
///      L1 spread is a quote offering a better price than L1, so an oracle anyone can write is an
///      oracle anyone can be paid out of. That gap between the two instances is the trust argument
///      stated as a deployment rather than as a claim: the demo desk trades mock tokens and this
///      oracle, the canonical desk trades real ones and the other.
///
///      Everything else about the path is identical — same `IMapOracle`, same staleness rule, same
///      `mapMinNotional` floor, same fail-closed reads in `CoreQuote` and `DeskHooks`. The demo
///      desk ships with a short `mapMaxAge`, so a posted map expires on its own and the lean goes
///      out without anybody clearing it. That is the fail-closed property being demonstrated, not
///      described.
contract DemoMapOracle is IMapOracle {
    /// @notice Who posted, kept beside the map itself so the page can name them.
    /// @dev `MapUpdated` is the interface event every consumer indexes; this is the extra fact only
    ///      a permissionless instance has. Two events rather than a wider one, so an indexer can
    ///      read both oracles with one handler.
    event DemoMapPosted(uint32 indexed perpIndex, address indexed poster, uint128 belowNotional, uint128 aboveNotional);

    mapping(uint32 perpIndex => LiquidationMap) internal _maps;
    mapping(uint32 perpIndex => address) public lastPoster;

    /// @notice Post the forced notional sitting within 1% of mark on each side. No caller check.
    /// @dev The timestamp is the chain's, exactly as in `MapOracle`: the staleness rule the desks
    ///      rely on is only worth anything if the clock is not the poster's.
    function update(uint32 perpIndex, uint128 belowNotional, uint128 aboveNotional) external {
        uint64 updatedAt = uint64(block.timestamp);
        _maps[perpIndex] =
            LiquidationMap({ belowNotional: belowNotional, aboveNotional: aboveNotional, updatedAt: updatedAt });
        lastPoster[perpIndex] = msg.sender;
        emit MapUpdated(perpIndex, belowNotional, aboveNotional, updatedAt);
        emit DemoMapPosted(perpIndex, msg.sender, belowNotional, aboveNotional);
    }

    function map(uint32 perpIndex) external view returns (LiquidationMap memory) {
        return _maps[perpIndex];
    }
}
