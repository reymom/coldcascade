// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Book } from "../src/interfaces/ICoreReader.sol";
import { HyperCore } from "../src/libs/HyperCore.sol";
import { DeskParamsLib } from "../src/libs/DeskParams.sol";
import { HyperCoreMock } from "./mocks/HyperCoreMock.sol";

/// @notice The precompiles carry no bytecode, so a fork returns empty data for them and every
///         decode here would revert. The mock is etched at their addresses instead. The numbers
///         are the quiet 999 book of 2026-09-04; the failure behaviour is what 998 does.
contract HyperCoreTest is Test {
    uint32 internal constant BTC = 0;

    uint64 internal constant QUIET_BID = 795_510;
    uint64 internal constant QUIET_ASK = 795_520;
    uint64 internal constant QUIET_MARK = 795_450;
    uint64 internal constant QUIET_ORACLE = 795_790;

    function setUp() public {
        HyperCoreMock template = new HyperCoreMock();
        bytes memory code = address(template).code;
        vm.etch(HyperCore.MARK_PX, code);
        vm.etch(HyperCore.ORACLE_PX, code);
        vm.etch(HyperCore.L1_BLOCK_NUMBER, code);
        vm.etch(HyperCore.BBO, code);
        vm.etch(HyperCore.PERP_ASSET_INFO, code);

        _bbo().setBbo(BTC, QUIET_BID, QUIET_ASK);
        _info().setAssetInfo(BTC, "BTC", 56, 5, 40, false);
        _mark().setPx(BTC, QUIET_MARK);
        _oracle().setPx(BTC, QUIET_ORACLE);
    }

    function test_bbo_decodesTwoWords() public view {
        (uint64 bid, uint64 ask) = HyperCore.bbo(BTC);
        assertEq(bid, QUIET_BID, "bid");
        assertEq(ask, QUIET_ASK, "ask");
    }

    function test_markAndOracle_decodeOneWord() public view {
        assertEq(HyperCore.markPx(BTC), QUIET_MARK, "mark");
        assertEq(HyperCore.oraclePx(BTC), QUIET_ORACLE, "oracle");
    }

    function test_l1BlockNumber_takesNoArgs() public {
        _l1Block().setL1Block(680_764_997);
        assertEq(HyperCore.l1BlockNumber(), 680_764_997);
    }

    /// @dev Perp index 3 is MATIC on 999 and its book is (0, 0) today. A desk that quoted off it
    ///      would be quoting off zero, so the read fails instead of returning a book.
    function test_emptyBook_reverts() public {
        Book memory b = HyperCore.book(BTC);
        assertEq(b.bid, QUIET_BID);

        _bbo().setBbo(3, 0, 0);
        _mark().setPx(3, 1);
        _oracle().setPx(3, 1);
        vm.expectRevert(abi.encodeWithSelector(HyperCore.EmptyBook.selector, uint32(3)));
        this.callBook(3);

        _bbo().setBbo(4, 1, 1);
        _oracle().setPx(4, 1);
        vm.expectRevert(abi.encodeWithSelector(HyperCore.EmptyBook.selector, uint32(4)));
        this.callBook(4);
    }

    function test_precompile_badLengthReverts() public {
        _bbo().setBboWords(1);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCore.PrecompileCallFailed.selector, HyperCore.BBO, BTC)
        );
        this.callBook(BTC);

        _bbo().setBboWords(3);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCore.PrecompileCallFailed.selector, HyperCore.BBO, BTC)
        );
        this.callBook(BTC);
    }

    /// @dev The hazard the cap exists for: on 998 a bad input consumes every gas unit forwarded.
    ///      Uncapped, that is 63/64 of the router's frame. Capped, it is PRECOMPILE_GAS_CAP and
    ///      the caller lives to revert.
    function test_precompileGasCapped() public {
        _bbo().setBurn(true);

        uint256 before = gasleft();
        try this.callBook(BTC) {
            fail();
        } catch { }
        uint256 spent = before - gasleft();

        assertGe(spent, HyperCore.PRECOMPILE_GAS_CAP, "the cap was not actually forwarded");
        assertLt(spent, HyperCore.PRECOMPILE_GAS_CAP * 2, "the burn escaped the cap");
    }

    /// @dev `szDecimals` is read at a fixed offset instead of through `abi.decode`, because the
    ///      dynamic decoder for `PerpAssetInfo` costs `DeskAccount` more code deposit than it has
    ///      room for in a 3 000 000 gas small block. That trade only holds if the offset is right,
    ///      so it is checked against the record 0x080a really returned for BTC on 999: coin "BTC",
    ///      margin table 56, szDecimals 5, 40x, cross.
    function test_szDecimals_readsTheFieldNotTheStruct() public view {
        assertEq(HyperCore.szDecimals(BTC), 5, "BTC on 999");
    }

    /// @dev The record moves and the read follows it. A second asset with different values in
    ///      every field is what catches an offset that happens to be right for one of them —
    ///      SOL on 998: margin table 10, szDecimals 2, 10x.
    function test_szDecimals_followsTheAsset() public {
        _info().setAssetInfo(7, "SOL", 10, 2, 10, false);
        assertEq(HyperCore.szDecimals(7), 2, "SOL on 998");
        assertEq(HyperCore.szDecimals(BTC), 5, "and BTC is unchanged");
    }

    /// @dev A record that is not the shape the offset assumes has to be an error. The alternative
    ///      is a plausible-looking wrong `szDecimals`, which would round every hedge onto the
    ///      wrong lot grid and price it off the wrong exponent without anything reverting. The
    ///      mock answers here with three words whose leading offset is 0x40 — non-empty, decodable
    ///      as *something*, and not this record.
    function test_szDecimals_rejectsAMalformedRecord() public {
        _info().setMalformAssetInfo(true);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCore.PrecompileCallFailed.selector, HyperCore.PERP_ASSET_INFO, BTC)
        );
        this.callSzDecimals(BTC);
    }

    function test_priceScale_btcOnUbtcUsdt0_is1Over1000() public pure {
        (uint64 num, uint64 den) = DeskParamsLib.priceScale(5, 8, 6);
        assertEq(num, 1, "pxNum");
        assertEq(den, 1000, "pxDen");

        // A raw BTC price of 795 510 is $79 551.0, so one UBTC unit is 795.51 USDT0 units.
        assertEq(uint256(QUIET_BID) * 1e8 * num / den, 79_551_000_000);

        (num, den) = DeskParamsLib.priceScale(2, 18, 6);
        assertEq(num, 1, "pxNum, 18-decimal base");
        assertEq(den, 1e16, "pxDen, 18-decimal base");
    }

    function callSzDecimals(uint32 perpIndex) external view returns (uint8) {
        return HyperCore.szDecimals(perpIndex);
    }

    function callBook(uint32 perpIndex) external view returns (Book memory) {
        return HyperCore.book(perpIndex);
    }

    function _info() private pure returns (HyperCoreMock) {
        return HyperCoreMock(payable(HyperCore.PERP_ASSET_INFO));
    }

    function _bbo() private pure returns (HyperCoreMock) {
        return HyperCoreMock(payable(HyperCore.BBO));
    }

    function _mark() private pure returns (HyperCoreMock) {
        return HyperCoreMock(payable(HyperCore.MARK_PX));
    }

    function _oracle() private pure returns (HyperCoreMock) {
        return HyperCoreMock(payable(HyperCore.ORACLE_PX));
    }

    function _l1Block() private pure returns (HyperCoreMock) {
        return HyperCoreMock(payable(HyperCore.L1_BLOCK_NUMBER));
    }
}
