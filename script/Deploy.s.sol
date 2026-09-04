// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";

/// @notice Chain 999. Reader (CorePrecompiles or BookCache, decided by the probe), CoreQuote,
///         DeskHooks, MapOracle, MarkoutLedger, the two demo tokens. Addresses go to
///         deployments/999.json for the subgraph and the page.
contract DeployScript is Script {
    function run() external {
        revert("todo");
    }
}
