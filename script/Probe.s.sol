// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";

import { Probe } from "../src/Probe.sol";

/// @notice Friday, testnet 998. Deploys Probe, then the answers come from cast:
///           cast call $PROBE "nested(uint32)" 0 --rpc-url $HYPERTESTNET_RPC_URL
///           cast call $PROBE "badInput(uint256)" 50000 --rpc-url $HYPERTESTNET_RPC_URL
contract ProbeScript is Script {
    function run() external {
        revert("todo");
    }
}
