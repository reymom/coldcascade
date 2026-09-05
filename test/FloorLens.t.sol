// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DeskTest } from "./base/DeskTest.sol";
import { DeskAccount } from "../src/DeskAccount.sol";
import { FloorLens } from "../src/FloorLens.sol";
import { DeskParams } from "../src/libs/DeskParams.sol";
import { Side } from "../src/libs/Regime.sol";

/// @notice One `eth_call` behind the whole screen. What is worth testing is that it agrees with the
///         contracts it reads, that a params-only row prices identically to a deployed one, and
///         that nothing a misconfigured desk can do takes the page down with it.
contract FloorLensTest is DeskTest {
    uint128 internal constant BASE_IN = 0.4e8;      // 0.4 UBTC
    uint128 internal constant QUOTE_IN = 12_000e6;  // 12 000 USDT0

    function none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function previewOf(DeskParams memory p) internal pure returns (DeskParams[] memory list) {
        list = new DeskParams[](1);
        list[0] = p;
    }

    function test_floor_carriesTheBookAndTheChain() public view {
        FloorLens.FloorView memory v = lens.floor(coreQuote, BTC, none(), new DeskParams[](0));

        assertTrue(v.bookOk);
        assertEq(v.book.bid, QUIET_BID);
        assertEq(v.book.ask, QUIET_ASK);
        assertEq(v.book.mark, QUIET_MARK);
        assertEq(v.book.oracle, QUIET_ORACLE);
        assertEq(v.blockNumber, block.number);
        assertEq(v.chainId, block.chainid);
        assertEq(v.desks.length, 0);
    }

    /// @dev The reason the lens exists: the four numbers on the screen come out of one frame, so
    ///      the desk's band is arithmetic on the L1 band beside it and not on a later one.
    function test_floor_bandIsArithmeticOnTheBookBesideIt() public view {
        DeskParams memory p = btcParams();
        FloorLens.FloorView memory v = lens.floor(coreQuote, BTC, none(), previewOf(p));

        FloorLens.DeskView memory d = v.desks[0];
        assertTrue(d.quoted);
        assertEq(d.bidPx, uint256(v.book.bid) * (10_000 - QUIET_BPS) / 10_000);
        assertEq(d.askPx, (uint256(v.book.ask) * (10_000 + QUIET_BPS) + 9_999) / 10_000);
        assertTrue(d.lean == Side.None);
    }

    /// @dev A params-only row is the canonical desk before it is deployed. It has to price exactly
    ///      as the deployed one does, or the Floor tells a different story on Sunday than on Monday.
    function test_floor_previewMatchesTheDeployedDesk() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = openDesk(maker, "canonical", p, BASE_IN, QUOTE_IN);

        FloorLens.FloorView memory v = lens.floor(coreQuote, BTC, one(address(desk)), previewOf(p));
        FloorLens.DeskView memory onChain = v.desks[0];
        FloorLens.DeskView memory preview = v.desks[1];

        assertEq(onChain.bidPx, preview.bidPx);
        assertEq(onChain.askPx, preview.askPx);
        assertTrue(onChain.lean == preview.lean);
        assertEq(onChain.account, address(desk));
        assertEq(preview.account, address(0), "and the preview says it has no account");
    }

    function test_floor_readsTheDesksOwnState() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = openDesk(maker, "canonical", p, BASE_IN, QUOTE_IN);

        FloorLens.DeskView memory d = lens.floor(coreQuote, BTC, one(address(desk)), new DeskParams[](0)).desks[0];
        assertEq(d.label, "canonical");
        assertEq(d.owner, maker);
        assertTrue(d.open);
        assertEq(d.strategyHash, desk.strategyHash());
        assertEq(d.baseBalance, BASE_IN);
        assertEq(d.quoteBalance, QUOTE_IN);
        assertEq(d.params.quietBps, QUIET_BPS);
        assertFalse(d.hedgeArmed);
        assertEq(d.coverBase, 0, "a fresh desk is square");
    }

    function test_floor_hedgeRowFollowsArmAndInventory() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = openDesk(maker, "canonical", p, BASE_IN, QUOTE_IN);

        vm.prank(maker);
        desk.armHedge(true, type(uint64).max, address(0));
        ubtc.mint(address(desk), 0.05e8);

        FloorLens.DeskView memory d = lens.floor(coreQuote, BTC, one(address(desk)), new DeskParams[](0)).desks[0];
        assertTrue(d.hedgeArmed);
        assertEq(d.coverBase, 0.05e8, "what it accumulated since it was last square");
        assertTrue(d.coverIsBuy == false, "long base sells the perp");
    }

    /// @dev The map column reads the desk's *own* oracle, so the two layers are distinguishable on
    ///      screen: a demo desk leaning off a map anyone posted, next to a canonical desk that is not.
    function test_floor_mapColumnIsPerDesk() public {
        DeskParams memory canonical = btcParams();
        canonical.mapOracle = address(mapOracle);
        DeskParams memory demo = btcParams();
        demo.mapOracle = address(demoMap);

        vm.prank(vm.addr(0x5EE));
        demoMap.update(BTC, MAP_MIN_NOTIONAL * 8, 0);

        DeskParams[] memory both = new DeskParams[](2);
        (both[0], both[1]) = (canonical, demo);
        FloorLens.FloorView memory v = lens.floor(coreQuote, BTC, none(), both);

        assertTrue(v.desks[0].lean == Side.None, "canonical, on the single-updater oracle");
        assertEq(v.desks[0].map.belowNotional, 0);
        assertTrue(v.desks[1].lean == Side.Bid, "demo, on the open one");
        assertEq(v.desks[1].map.belowNotional, MAP_MIN_NOTIONAL * 8);
        assertTrue(v.desks[1].regime.mapFresh);
    }

    /// @dev An unreadable book is an empty band, not a dead page and not an invented price.
    function test_floor_unreadableBookIsAnEmptyBand() public {
        setBookAt(3, 0, 0, 0, 0);
        DeskParams memory p = btcParams();
        p.perpIndex = 3;

        FloorLens.FloorView memory v = lens.floor(coreQuote, 3, none(), previewOf(p));
        assertFalse(v.bookOk);
        assertFalse(v.desks[0].quoted);
        assertEq(v.desks[0].bidPx, 0);
    }

    /// @dev One bad row cannot take the others with it.
    function test_floor_anAddressThatIsNotADeskIsABlankRow() public {
        DeskParams memory p = btcParams();
        DeskAccount desk = openDesk(maker, "canonical", p, BASE_IN, QUOTE_IN);

        address[] memory accounts = new address[](2);
        (accounts[0], accounts[1]) = (address(0xDEAD), address(desk));

        FloorLens.FloorView memory v = lens.floor(coreQuote, BTC, accounts, new DeskParams[](0));
        assertEq(v.desks[0].account, address(0xDEAD));
        assertFalse(v.desks[0].quoted, "no params, so no price");
        assertEq(v.desks[1].label, "canonical", "and the real desk beside it is unaffected");
    }
}
