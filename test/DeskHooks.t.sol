// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DeskTest } from "./base/DeskTest.sol";

contract DeskHooksTest is DeskTest {
    function test_fill_emitsBookState() public {
        vm.skip(true);
    }

    function test_fill_onlyRouter() public {
        vm.skip(true);
    }

    function test_quotePath_neverCallsHook() public {
        vm.skip(true);
    }
}
