// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DeskTest } from "./base/DeskTest.sol";

/// @notice The screen. Two makers from one wallet, the same inventory, the same tape, an arb taker
///         and a flow taker every minute, both inventories marked at spot. Writes
///         results/oct10_replay.csv; the last row is the two numbers.
///
///         forge test --match-contract Oct10Replay -vv
contract Oct10ReplayTest is DeskTest {
    /// @dev One minute of tape/oct10_btc_1m.json. Fields alphabetical: vm.parseJson decodes structs
    ///      in that order.
    struct Tick {
        uint64 ask;
        uint64 bid;
        uint256 forcedBuyNtl;
        uint256 forcedSellNtl;
        uint64 mark;
        uint64 oracle;
        uint256 spot;
        uint256 t;
        uint256 takerNtl;
    }

    /// @dev What one minute leaves behind for both makers.
    struct Row {
        uint256 t;
        int256 pnlControlBps;
        int256 pnlDeskBps;
        uint256 baseControl;
        uint256 baseDesk;
        uint8 lean;
        uint256 absorbedNtl;
    }

    uint16 internal constant ARB_EDGE_BPS = 10;       // todo: set from the dry run
    uint16 internal constant FLOW_CAPTURE_BPS = 100;  // share of the minute's forced notional routed here

    function loadTape() internal view returns (Tick[] memory) {
        revert("todo");
    }

    /// @notice If a maker's marginal price is off spot by more than the edge, trade it back.
    ///         For the desk this mostly finds nothing to do, which is the point.
    function arbTaker(Tick memory tick) internal {
        revert("todo");
    }

    /// @notice Route the minute's forced flow to whoever quotes best, best price first.
    function flowTaker(Tick memory tick) internal returns (uint256 absorbedNtl) {
        revert("todo");
    }

    function markToSpot(Tick memory tick) internal view returns (Row memory) {
        revert("todo");
    }

    function writeRow(Row memory row) internal {
        revert("todo");
    }

    function test_replay_writesResults() public {
        vm.skip(true);
    }

    function test_replay_isDeterministic() public {
        vm.skip(true);
    }

    function test_replay_fillsCarryMarkouts() public {
        vm.skip(true);
    }
}
