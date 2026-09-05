// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { console } from "forge-std/console.sol";

import { Addresses } from "./base/Addresses.sol";
import { BookCache } from "../src/BookCache.sol";
import { CorePrecompiles } from "../src/CorePrecompiles.sol";
import { CoreQuote } from "../src/CoreQuote.sol";
import { DemoMapOracle } from "../src/DemoMapOracle.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { DeskAccount } from "../src/DeskAccount.sol";
import { DeskFactory } from "../src/DeskFactory.sol";
import { DeskHooks } from "../src/DeskHooks.sol";
import { FloorLens } from "../src/FloorLens.sol";
import { MapOracle } from "../src/MapOracle.sol";
import { MarkoutLedger } from "../src/MarkoutLedger.sol";

/// @notice Everything the console and the keeper address, in one broadcast, ending in
///         `deployments/<chainid>.json`.
///
///         forge script script/Deploy.s.sol --rpc-url hyperevm --account $DEPLOYER_ACCOUNT \
///           --sender $DEPLOYER --broadcast
///
/// @dev The reader is `CorePrecompiles`, not `BookCache`: a `view` target reached through
///      STATICCALL reads `0x080e` at the same price as at depth one, measured on 998
///      (`results/998_precompiles.md`). `BookCache` is deployed beside it because it is the only
///      history of the book that exists — the precompiles ignore the block tag
///      (`results/999_live_quote.md`) — and the keeper pokes it so markouts have a later book.
///
///      Two map oracles, and the difference is the point. `MapOracle` has one updater and is what
///      the canonical desk names. `DemoMapOracle` is permissionless and is what the demo desk
///      names, so a visitor can put a desk into a lean without being able to reach one that holds
///      anything.
contract DeployScript is Addresses {
    function run() external {
        address deployer = msg.sender;
        address mapUpdater = vm.envOr("MAP_UPDATER", deployer);
        address markoutPoster = vm.envOr("MARKOUT_POSTER", deployer);

        vm.startBroadcast();

        CorePrecompiles precompiles = new CorePrecompiles();
        BookCache bookCache = new BookCache();
        CoreQuote coreQuote = new CoreQuote(precompiles);
        DeskHooks hooks = new DeskHooks(router(), precompiles);
        MapOracle mapOracle = new MapOracle(mapUpdater);
        DemoMapOracle demoMapOracle = new DemoMapOracle();
        MarkoutLedger markoutLedger = new MarkoutLedger(markoutPoster);
        FloorLens lens = new FloorLens();
        // Two transactions, not one: the account's code deposit is most of a small block on its
        // own, so a factory that built it in its own constructor would never be mined.
        DeskAccount implementation = new DeskAccount(IAqua(aqua()), router(), address(coreQuote), address(hooks));
        DeskFactory factory = new DeskFactory(implementation);

        // The mock layer. Real decimals, public mint: what a visitor opens a desk with and takes
        // against. The book both layers price from is the same one, and it is not mocked.
        DemoToken ubtc = new DemoToken("Demo Unit Bitcoin", "dUBTC", 8);
        DemoToken usdt0 = new DemoToken("Demo Tether USD0", "dUSDT0", 6);

        vm.stopBroadcast();

        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "deployedAtBlock", block.number);
        vm.serializeAddress(json, "aqua", aqua());
        vm.serializeAddress(json, "router", router());
        vm.serializeAddress(json, "corePrecompiles", address(precompiles));
        vm.serializeAddress(json, "bookCache", address(bookCache));
        vm.serializeAddress(json, "coreQuote", address(coreQuote));
        vm.serializeAddress(json, "deskHooks", address(hooks));
        vm.serializeAddress(json, "mapOracle", address(mapOracle));
        vm.serializeAddress(json, "mapUpdater", mapUpdater);
        vm.serializeAddress(json, "demoMapOracle", address(demoMapOracle));
        vm.serializeAddress(json, "markoutLedger", address(markoutLedger));
        vm.serializeAddress(json, "floorLens", address(lens));
        vm.serializeAddress(json, "deskAccountImplementation", address(implementation));
        vm.serializeAddress(json, "deskFactory", address(factory));
        vm.serializeAddress(json, "demoBase", address(ubtc));
        string memory out = vm.serializeAddress(json, "demoQuote", address(usdt0));
        vm.writeJson(out, deploymentsPath());

        console.log("wrote", deploymentsPath());
    }
}
