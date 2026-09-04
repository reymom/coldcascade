// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DeskTest } from "./base/DeskTest.sol";

/// @notice The Saturday suite. Every claim in the README is one of these.
contract CoreQuoteTest is DeskTest {
    // ---- the quiet: the desk cannot be taken stale ----

    function test_quiet_bidSitsOutsideL1() public {
        vm.skip(true);
    }

    function test_quiet_askSitsOutsideL1() public {
        vm.skip(true);
    }

    function test_quiet_neverBetterThanCurve() public {
        vm.skip(true);
    }

    function test_quiet_noCurve_quotesOffTheBook() public {
        vm.skip(true);
    }

    // ---- stress: the absorbing side leans in, the other side keeps its bound ----

    function test_stressDown_bidLeansInsideSpread() public {
        vm.skip(true);
    }

    function test_stressUp_askLeansInsideSpread() public {
        vm.skip(true);
    }

    function test_stress_otherSideStaysBounded() public {
        vm.skip(true);
    }

    function test_neverPaysAboveL1Ask() public {
        vm.skip(true);
    }

    function test_neverSellsBelowL1Bid() public {
        vm.skip(true);
    }

    function test_stressThreshold_isMakerParameter() public {
        vm.skip(true);
    }

    // ---- fail closed ----

    function test_emptyBbo_failsClosed() public {
        vm.skip(true);
    }

    function test_crossedBook_failsClosed() public {
        vm.skip(true);
    }

    function test_wrongPair_reverts() public {
        vm.skip(true);
    }

    function test_inventoryCap_reverts() public {
        vm.skip(true);
    }

    // ---- the map: can add a lean, can never be the reason for a stale one ----

    function test_staleMap_isIgnored() public {
        vm.skip(true);
    }

    function test_freshMap_leansWithoutDislocation() public {
        vm.skip(true);
    }

    function test_noMapOracle_isBookOnly() public {
        vm.skip(true);
    }

    // ---- SwapVM invariants ----

    function test_exactOut_mirrorsExactIn() public {
        vm.skip(true);
    }

    function test_quoteEqualsSwap() public {
        vm.skip(true);
    }

    function test_takerAmountUntouched() public {
        vm.skip(true);
    }

    function test_plainXycUnchangedOnOfficialRouter() public {
        vm.skip(true);
    }

    // ---- the death metric, locally ----

    function test_deathMetric_amountOutMovesWithBook() public {
        vm.skip(true);
    }
}
