// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";

import { DeskParams, DeskParamsLib } from "../../src/libs/DeskParams.sol";

/// @notice The address book and the canonical parameters, shared by the three scripts.
/// @dev Everything is an env var with a default, so Monday's deploy is one command and Monday's
///      real token addresses drop in without touching a line of Solidity. `deployments/<chainid>.json`
///      is the handoff: `Deploy` writes it, `Ship` and `Swap` read it, and so does the console.
abstract contract Addresses is Script {
    /// @dev 1inch's own deployment on 999. `cast code` on both, 2026-09-05: 5 620 and 20 542 bytes.
    address internal constant AQUA_999 = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    address internal constant ROUTER_999 = 0x111111338c5091E8440b67B168bAe16a668AC0De;

    /// @dev BTC's szDecimals on 999, from `perpAssetInfo(0)` on a live node (2026-09-04). It cannot
    ///      be read from a script: the precompiles have no bytecode, so the fork the script runs
    ///      against returns nothing for them.
    uint8 internal constant BTC_SZ_DECIMALS = 5;

    function deploymentsPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    function readAddress(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(vm.readFile(deploymentsPath()), string.concat(".", key));
    }

    function aqua() internal view returns (address) {
        return vm.envOr("AQUA", AQUA_999);
    }

    function router() internal view returns (address) {
        return vm.envOr("SWAPVM_ROUTER", ROUTER_999);
    }

    /// @notice The canonical desk's parameters, over a pair whose decimals are read on chain.
    /// @dev The spreads are the provisional band the suite quotes: 20 bps outside when quiet, 15
    ///      bps inside when absorbing, book-alone stress at 25 bps of dislocation. `minBase` is
    ///      zero because a quote arrives with `balanceOut` unset — `SwapVM.quote` zeroes both
    ///      balance registers — so a non-zero floor would make every quote revert before a taker
    ///      ever saw a price.
    function canonicalParams(address base, address quote, address mapOracle, uint32 mapMaxAge)
        internal
        view
        returns (DeskParams memory p)
    {
        (uint64 pxNum, uint64 pxDen) = DeskParamsLib.priceScale(
            uint8(vm.envOr("SZ_DECIMALS", uint256(BTC_SZ_DECIMALS))),
            _decimals(base),
            _decimals(quote)
        );
        p = DeskParams({
            base: base,
            quote: quote,
            perpIndex: uint32(vm.envOr("PERP_INDEX", uint256(0))),
            pxNum: pxNum,
            pxDen: pxDen,
            quietBps: uint16(vm.envOr("QUIET_BPS", uint256(20))),
            leanBps: uint16(vm.envOr("LEAN_BPS", uint256(15))),
            stressBps: uint16(vm.envOr("STRESS_BPS", uint256(25))),
            mapOracle: mapOracle,
            mapMaxAge: mapMaxAge,
            mapMinNotional: uint128(vm.envOr("MAP_MIN_NOTIONAL", uint256(5_000_000))),
            minBase: 0,
            maxBase: uint128(vm.envOr("MAX_BASE", type(uint128).max))
        });
    }

    function _decimals(address token) private view returns (uint8) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && ret.length == 32, "token has no decimals()");
        return abi.decode(ret, (uint8));
    }
}
