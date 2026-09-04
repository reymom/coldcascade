// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AquaSwapVMTest } from "@1inch/swap-vm/test/base/AquaSwapVMTest.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { CoreQuote } from "../../src/CoreQuote.sol";
import { DeskHooks } from "../../src/DeskHooks.sol";
import { MapOracle } from "../../src/MapOracle.sol";
import { DemoToken } from "../../src/DemoToken.sol";
import { DeskParams } from "../../src/libs/DeskParams.sol";
import { HyperCore } from "../../src/libs/HyperCore.sol";
import { MockCoreReader } from "../mocks/MockCoreReader.sol";
import { HyperCoreMock } from "../mocks/HyperCoreMock.sol";

/// @notice Every desk test extends 1inch's own Aqua harness: their Aqua, their router, their
///         MockTaker. What is added is the pair with real decimals, the reader, the hook and the
///         canonical orders.
abstract contract DeskTest is AquaSwapVMTest {
    uint32 internal constant BTC = 0;

    /// @dev Quiet book on 999 at block 45 021 360, 2026-09-04. Raw units, szDecimals 5.
    uint64 internal constant QUIET_BID = 795_510;
    uint64 internal constant QUIET_ASK = 795_520;
    uint64 internal constant QUIET_MARK = 795_450;
    uint64 internal constant QUIET_ORACLE = 795_790;

    DemoToken internal ubtc;
    DemoToken internal usdt0;
    MockCoreReader internal reader;
    CoreQuote internal coreQuote;
    DeskHooks internal hooks;
    MapOracle internal mapOracle;

    function setUp() public virtual override {
        super.setUp();
        // todo: ubtc/usdt0, reader, coreQuote(reader), hooks(router, reader), mapOracle(this)
    }

    /// @notice Default parameters for BTC on UBTC(8)/USDT0(6), book-only. Tests override fields.
    function btcParams() internal view returns (DeskParams memory) {
        revert("todo");
    }

    function deskOrder(DeskParams memory p, bytes32 salt) internal view returns (ISwapVM.Order memory) {
        revert("todo");
    }

    function controlOrder(bytes32 salt) internal view returns (ISwapVM.Order memory) {
        revert("todo");
    }

    /// @notice Sets the book on the mock reader and, if etched, on the precompile mocks.
    function setBook(uint64 bid, uint64 ask, uint64 mark, uint64 oracle) internal {
        revert("todo");
    }

    /// @notice Plants HyperCoreMock at 0x0806, 0x0807, 0x0809 and 0x080e.
    /// @dev One bytecode at four addresses. Storage is per-address and vm.etch copies neither, so
    ///      every instance starts blank and each is set through its own setter.
    function etchHyperCore() internal {
        bytes memory code = address(new HyperCoreMock()).code;
        vm.etch(HyperCore.MARK_PX, code);
        vm.etch(HyperCore.ORACLE_PX, code);
        vm.etch(HyperCore.L1_BLOCK_NUMBER, code);
        vm.etch(HyperCore.BBO, code);
    }
}
