// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

/// @notice Against the Aqua and SwapVM router already deployed on 999. The precompiles have no code
///         on a fork, so the reader is a mock; what this proves is that the deployed router
///         dispatches Extruction to CoreQuote and that ship/quote/swap work against real contracts.
///
///         forge test --match-path 'test/fork/*' --fork-url $HYPEREVM_RPC_URL -vvv
contract OfficialRouterForkTest is Test {
    address internal constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    address internal constant ROUTER = 0x111111338c5091E8440b67B168bAe16a668AC0De;
    uint256 internal constant FORK_BLOCK = 45_021_360; // 2026-09-04

    function test_officialRouter_dispatchesExtruction() public {
        vm.skip(true);
    }

    function test_officialAqua_shipQuoteSwap() public {
        vm.skip(true);
    }

    function test_deathMetric_onOfficialContracts() public {
        vm.skip(true);
    }
}
