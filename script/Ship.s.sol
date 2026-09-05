// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { console } from "forge-std/console.sol";

import { Addresses } from "./base/Addresses.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { DeskAccount } from "../src/DeskAccount.sol";
import { DeskFactory } from "../src/DeskFactory.sol";
import { DeskParams } from "../src/libs/DeskParams.sol";
import { DeskPrograms } from "../src/libs/DeskPrograms.sol";

/// @notice Opens the three strategies the Floor shows, and writes their addresses back into
///         `deployments/<chainid>.json`.
///
///         forge script script/Ship.s.sol --rpc-url hyperevm --account $DEPLOYER_ACCOUNT \
///           --sender $DEPLOYER --broadcast
///
/// @dev **Two layers, and only the tokens differ.**
///
///      - **canonical** — a `DeskAccount` on the real pair, funded with real size, pointing at
///        `MapOracle`, whose updater is one address. This is the desk a taker is actually paid by
///        and the only one that can lose money.
///      - **control** — the same pair and the same inventory, shipped from the deployer's own EOA
///        as plain `XYCSwap` with no hook and no book bound. It is the other line on the screen:
///        whatever the desk's quote does when the book moves, this one does not.
///      - **demo** — the same program over `DemoToken`s anyone can mint, pointing at
///        `DemoMapOracle`, which anyone can write, with a short `mapMaxAge`. A visitor opens, takes
///        and leans against this one.
///
///      Both layers read the same live HyperCore book. The mock is the token, never the price.
///
///      `BASE_TOKEN` / `QUOTE_TOKEN` default to the deployed demo pair, so this runs end to end
///      before any real inventory exists; set them to the real pair on the day it does.
contract ShipScript is Addresses {
    using SafeERC20 for IERC20;

    /// @dev The canonical desk's map is minutes-scale, because the keeper posts on a cadence. The
    ///      demo's is short on purpose: a map a visitor posts has to expire while they are still
    ///      looking at the screen, which is the fail-closed rule demonstrating itself.
    uint32 internal constant CANONICAL_MAP_MAX_AGE = 300;
    uint32 internal constant DEMO_MAP_MAX_AGE = 180;

    function run() external {
        address deployer = msg.sender;
        DeskFactory factory = DeskFactory(readAddress("deskFactory"));
        address demoBase = readAddress("demoBase");
        address demoQuote = readAddress("demoQuote");

        address base = vm.envOr("BASE_TOKEN", demoBase);
        address quote = vm.envOr("QUOTE_TOKEN", demoQuote);

        DeskParams memory canonical = canonicalParams(base, quote, readAddress("mapOracle"), CANONICAL_MAP_MAX_AGE);
        DeskParams memory demo = canonicalParams(demoBase, demoQuote, readAddress("demoMapOracle"), DEMO_MAP_MAX_AGE);

        uint256 canonicalBase = vm.envOr("CANONICAL_BASE", uint256(0.000125e8)); // ~$10 of BTC at $80k
        uint256 canonicalQuote = vm.envOr("CANONICAL_QUOTE", uint256(10e6));     // $10
        uint256 demoBaseAmount = vm.envOr("DEMO_BASE", uint256(2e8));            // 2 dUBTC
        uint256 demoQuoteAmount = vm.envOr("DEMO_QUOTE", uint256(160_000e6));    // 160 000 dUSDT0

        vm.startBroadcast();

        _fund(base, deployer, canonicalBase, demoBase, demoQuote);
        _fund(quote, deployer, canonicalQuote, demoBase, demoQuote);
        _fund(demoBase, deployer, demoBaseAmount, demoBase, demoQuote);
        _fund(demoQuote, deployer, demoQuoteAmount, demoBase, demoQuote);

        IERC20(base).forceApprove(address(factory), canonicalBase);
        IERC20(quote).forceApprove(address(factory), canonicalQuote);
        (address canonicalDesk,) = factory.open("canonical", canonical, canonicalBase, canonicalQuote);

        IERC20(demoBase).forceApprove(address(factory), demoBaseAmount);
        IERC20(demoQuote).forceApprove(address(factory), demoQuoteAmount);
        (address demoDesk,) = factory.open("demo", demo, demoBaseAmount, demoQuoteAmount);

        bytes32 controlHash = _shipControl(deployer, canonical, canonicalBase, canonicalQuote);

        vm.stopBroadcast();

        string memory path = deploymentsPath();
        vm.writeJson(vm.toString(canonicalDesk), path, ".canonicalDesk");
        vm.writeJson(vm.toString(demoDesk), path, ".demoDesk");
        vm.writeJson(vm.toString(deployer), path, ".controlMaker");
        vm.writeJson(vm.toString(controlHash), path, ".controlStrategy");

        console.log("canonical", canonicalDesk);
        console.log("demo     ", demoDesk);
        console.log("control  ", deployer);
    }

    /// @dev The other line on the screen ships from a plain EOA, which is also the proof that the
    ///      account is a convenience and not a requirement: Aqua's maker is whoever called `ship`.
    function _shipControl(address maker, DeskParams memory p, uint256 amountBase, uint256 amountQuote)
        private
        returns (bytes32)
    {
        IAqua aquaContract = IAqua(aqua());
        IERC20(p.base).forceApprove(address(aquaContract), type(uint256).max);
        IERC20(p.quote).forceApprove(address(aquaContract), type(uint256).max);

        bytes32 salt = keccak256(abi.encode(maker, "control", block.timestamp));
        ISwapVM.Order memory o = DeskPrograms.order(maker, address(0), DeskPrograms.control(salt), p);

        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (amountBase, amountQuote);
        return aquaContract.ship(router(), DeskPrograms.strategyBytes(o), DeskPrograms.tokens(p), amounts);
    }

    /// @dev A demo token is minted; a real one has to already be there, and the script says so
    ///      rather than failing later inside `open` with a transfer error.
    function _fund(address token, address to, uint256 amount, address demoBase, address demoQuote) private {
        if (amount == 0) return;
        if (token == demoBase || token == demoQuote) {
            DemoToken(token).mint(to, amount);
            return;
        }
        require(IERC20(token).balanceOf(to) >= amount, "fund the deployer with the real pair first");
    }
}
