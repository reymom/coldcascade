// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DeskTest } from "./base/DeskTest.sol";
import { IMarkoutLedger } from "../src/interfaces/IMarkoutLedger.sol";
import { MarkoutLedger } from "../src/MarkoutLedger.sol";

/// @notice Where the keeper writes back what it computed from indexed fills. It is a log, so the
///         only things to check are who may write it and that the timestamp is the chain's.
contract MarkoutLedgerTest is DeskTest {
    function test_post_onlyPoster() public {
        address stranger = vm.addr(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MarkoutLedger.NotPoster.selector, stranger));
        markoutLedger.post(bytes32(uint256(1)), bytes32(uint256(2)), 60, -31);
    }

    function test_post_emitsMarkout() public {
        vm.warp(1_760_000_000);
        vm.expectEmit(true, true, false, true, address(markoutLedger));
        emit IMarkoutLedger.Markout(bytes32(uint256(1)), bytes32(uint256(2)), 60, -31, uint64(block.timestamp));
        markoutLedger.post(bytes32(uint256(1)), bytes32(uint256(2)), 60, -31);
    }

    /// @dev Signed, because a markout that can only be positive is not a measurement.
    function test_post_carriesTheSign() public {
        vm.expectEmit(true, true, false, true, address(markoutLedger));
        emit IMarkoutLedger.Markout(bytes32(uint256(3)), bytes32(uint256(4)), 5, 112, uint64(block.timestamp));
        markoutLedger.post(bytes32(uint256(3)), bytes32(uint256(4)), 5, 112);
    }
}
