// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DeskTest } from "./base/DeskTest.sol";
import { IMapOracle, LiquidationMap } from "../src/interfaces/IMapOracle.sol";
import { MapOracle } from "../src/MapOracle.sol";

/// @notice The one trusted write in the system, so the only thing worth testing about it is who
///         may make it and that the clock on it is the chain's.
contract MapOracleTest is DeskTest {
    function test_update_onlyUpdater() public {
        address stranger = vm.addr(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MapOracle.NotUpdater.selector, stranger));
        mapOracle.update(BTC, 10_000_000, 0);

        assertEq(mapOracle.UPDATER(), address(this), "the harness is the updater");
        mapOracle.update(BTC, 10_000_000, 0);
        assertEq(mapOracle.map(BTC).belowNotional, 10_000_000);
    }

    function test_update_emitsMapUpdated() public {
        vm.warp(1_760_000_000);
        vm.expectEmit(true, false, false, true, address(mapOracle));
        emit IMapOracle.MapUpdated(BTC, 10_000_000, 2_000_000, uint64(block.timestamp));
        mapOracle.update(BTC, 10_000_000, 2_000_000);
    }

    /// @dev The timestamp is the chain's, not the keeper's: a keeper that could stamp its own
    ///      updates could keep a stale map looking fresh, which is the one thing staleness is for.
    function test_map_carriesTimestamp() public {
        vm.warp(1_760_000_000);
        mapOracle.update(BTC, 10_000_000, 2_000_000);

        LiquidationMap memory m = mapOracle.map(BTC);
        assertEq(m.belowNotional, 10_000_000);
        assertEq(m.aboveNotional, 2_000_000);
        assertEq(m.updatedAt, 1_760_000_000, "stamped by the chain");

        vm.warp(block.timestamp + 60);
        assertEq(mapOracle.map(BTC).updatedAt, 1_760_000_000, "and not moved by reading it");

        LiquidationMap memory never = mapOracle.map(3);
        assertEq(never.updatedAt, 0, "a perp nobody posted reads as no map at all");
    }
}
