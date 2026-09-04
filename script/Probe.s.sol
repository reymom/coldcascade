// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console } from "forge-std/Script.sol";

import { Probe } from "../src/Probe.sol";

/// @notice Deploys Probe to testnet 998, where the precompiles are live:
///
///   forge script script/Probe.s.sol --rpc-url hypertestnet --account $DEPLOYER_ACCOUNT --broadcast
///   cast call $PROBE "nested(uint32)(uint64,uint64,uint256)" 0 --rpc-url hypertestnet
///   cast call $PROBE "badInput(uint256)(bool,uint256)" 30000 --rpc-url hypertestnet
///
/// @dev Do not run this without --broadcast expecting an answer. A dry run executes in revm
///      against a fork, the precompiles have no bytecode there, and every read comes back empty.
///      Only the node can answer, which is the whole reason this contract exists.
///
///      script/probe998.sh takes the same measurements with no deployment and no funded key, by
///      running Probe's own runtime bytecode through an eth_call state override. Prefer it: it
///      needs nothing but an RPC URL, so anyone can reproduce the numbers in results/.
contract ProbeScript is Script {
    function run() external returns (Probe probe) {
        vm.startBroadcast();
        probe = new Probe();
        vm.stopBroadcast();
        console.log("Probe", address(probe));
    }
}
