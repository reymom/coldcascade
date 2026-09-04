// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { HyperCore } from "../src/libs/HyperCore.sol";
import { HyperCoreMock } from "./mocks/HyperCoreMock.sol";

contract HyperCoreTest is Test {
    function test_bbo_decodesTwoWords() public {
        vm.skip(true);
    }

    function test_markAndOracle_decodeOneWord() public {
        vm.skip(true);
    }

    function test_l1BlockNumber_takesNoArgs() public {
        vm.skip(true);
    }

    function test_emptyBook_reverts() public {
        vm.skip(true);
    }

    function test_precompile_badLengthReverts() public {
        vm.skip(true);
    }

    function test_precompileGasCapped() public {
        vm.skip(true);
    }

    function test_priceScale_btcOnUbtcUsdt0_is1Over1000() public {
        vm.skip(true);
    }
}
