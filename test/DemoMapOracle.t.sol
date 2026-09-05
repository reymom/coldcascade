// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DeskTest } from "./base/DeskTest.sol";
import { CoreQuote } from "../src/CoreQuote.sol";
import { DemoMapOracle } from "../src/DemoMapOracle.sol";
import { IMapOracle, LiquidationMap } from "../src/interfaces/IMapOracle.sol";
import { DeskParams } from "../src/libs/DeskParams.sol";
import { Side } from "../src/libs/Regime.sol";

/// @notice The map with the trust taken out. What is worth testing is that it really is open, that
///         a desk pointed at it really does lean, and that the lean goes out on its own — the three
///         things a visitor is being shown when they press the button.
contract DemoMapOracleTest is DeskTest {
    uint32 internal constant DEMO_MAP_MAX_AGE = 180;

    function demoParams() internal view returns (DeskParams memory p) {
        p = btcParams();
        p.mapOracle = address(demoMap);
        p.mapMaxAge = DEMO_MAP_MAX_AGE;
    }

    function test_update_isPermissionless() public {
        address visitor = vm.addr(0x5EE);
        vm.prank(visitor);
        demoMap.update(BTC, 40_000_000, 0);

        LiquidationMap memory m = demoMap.map(BTC);
        assertEq(m.belowNotional, 40_000_000);
        assertEq(m.updatedAt, uint64(block.timestamp), "the chain's clock, same as the real one");
        assertEq(demoMap.lastPoster(BTC), visitor, "and it names who did it");
    }

    function test_update_emitsBothEvents() public {
        address visitor = vm.addr(0x5EE);
        vm.expectEmit(true, false, false, true, address(demoMap));
        emit IMapOracle.MapUpdated(BTC, 40_000_000, 0, uint64(block.timestamp));
        vm.expectEmit(true, true, false, true, address(demoMap));
        emit DemoMapOracle.DemoMapPosted(BTC, visitor, 40_000_000, 0);
        vm.prank(visitor);
        demoMap.update(BTC, 40_000_000, 0);
    }

    /// @dev The whole point of the button: a quiet book, a posted map, and the bid side crosses
    ///      inside L1. Nothing else about the desk changes.
    function test_postedMap_movesTheQuoteInsideL1() public {
        DeskParams memory p = demoParams();

        (uint256 quietBid,, Side quietLean) = coreQuote.bounds(p);
        assertTrue(quietLean == Side.None, "the book alone is quiet");
        assertLt(quietBid, QUIET_BID, "so the desk sits outside L1");

        demoMap.update(BTC, MAP_MIN_NOTIONAL * 8, 0);

        (uint256 leaningBid,, Side lean) = coreQuote.bounds(p);
        assertTrue(lean == Side.Bid, "a fresh map above the floor leans the absorbing side in");
        assertGt(leaningBid, QUIET_BID, "and that side is now inside L1's own bid");
    }

    /// @dev Fail-closed, demonstrated rather than described: nobody clears the map, it simply stops
    ///      counting, and the desk is back outside L1 the second it is older than mapMaxAge.
    function test_theLeanExpiresOnItsOwn() public {
        DeskParams memory p = demoParams();
        demoMap.update(BTC, MAP_MIN_NOTIONAL * 8, 0);
        (,, Side lean) = coreQuote.bounds(p);
        assertTrue(lean == Side.Bid);

        vm.warp(block.timestamp + DEMO_MAP_MAX_AGE);
        (,, Side atTheEdge) = coreQuote.bounds(p);
        assertTrue(atTheEdge == Side.Bid, "still fresh at exactly mapMaxAge");

        vm.warp(block.timestamp + 1);
        (uint256 bidPx,, Side expired) = coreQuote.bounds(p);
        assertTrue(expired == Side.None, "and gone one second later, with nobody clearing it");
        assertLt(bidPx, QUIET_BID, "the desk is outside L1 again");

        assertEq(demoMap.map(BTC).belowNotional, MAP_MIN_NOTIONAL * 8, "the map itself is untouched");
    }

    /// @dev A map under the desk's own floor is not stress. The demo cannot lean a desk that did
    ///      not ask to be leaned by that much, which is the parameter doing its job.
    function test_aMapBelowTheFloorDoesNothing() public {
        DeskParams memory p = demoParams();
        demoMap.update(BTC, MAP_MIN_NOTIONAL - 1, 0);
        (,, Side lean) = coreQuote.bounds(p);
        assertTrue(lean == Side.None);
    }

    /// @dev The deployment *is* the trust argument: the canonical desk names the single-updater
    ///      oracle, so nothing a visitor posts here can reach a desk holding real inventory.
    function test_theCanonicalDeskDoesNotPointHere() public {
        DeskParams memory canonical = btcParams();
        canonical.mapOracle = address(mapOracle);

        demoMap.update(BTC, MAP_MIN_NOTIONAL * 8, 0);

        (,, Side lean) = coreQuote.bounds(canonical);
        assertTrue(lean == Side.None, "a desk on the real oracle is untouched by the demo one");
        assertTrue(address(mapOracle) != address(demoMap));
    }
}
