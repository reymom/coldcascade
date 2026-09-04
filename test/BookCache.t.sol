// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DeskTest } from "./base/DeskTest.sol";

contract BookCacheTest is DeskTest {
    function test_poke_isPermissionless() public {
        vm.skip(true);
    }

    function test_poke_emitsBooked() public {
        vm.skip(true);
    }

    function test_read_matchesLastPoke() public {
        vm.skip(true);
    }

    function test_read_beforeAnyPoke_reverts() public {
        vm.skip(true);
    }
}
