// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { Addresses } from "./base/Addresses.sol";
import { DeskParams } from "../src/libs/DeskParams.sol";

/// @notice The four calls that take a desk through the official SwapVM router — printed, not sent.
///
///         DESK=0x… SELL_BASE=false AMOUNT=1000000000 TAKER=0x… \
///           forge script script/Swap.s.sol --rpc-url hyperevm
///
/// @dev **Why this prints instead of broadcasting.** `forge script` runs the body of `run()` in its
///      own EVM and only then sends whatever transactions the body collected — including the ones
///      inside `vm.startBroadcast()`. That EVM is a fork, and the HyperCore precompiles hold no
///      bytecode to fork: a call to `0x080e` lands on an empty account, returns nothing, and
///      `HyperCore._call`'s length check reverts with `PrecompileCallFailed` before a single
///      transaction exists. So `bounds()`, `quote()` and `swap()` are all unreachable from here,
///      and `--skip-simulation` does not help — it skips the simulation of transactions already
///      collected, not the execution that collects them.
///
///      The node does serve the precompiles. So this script does the part a fork can do — read the
///      account's own state and encode calldata — and hands the part that needs the book to `cast`,
///      which talks to the node. Everything below is a view; there is nothing here to broadcast.
///
///      The order is read back from the account with `order()` rather than rebuilt. Aqua keys a
///      strategy by the hash of the exact bytes that were shipped, so an order assembled a second
///      time from the same parameters is one wrong byte away from being a different, unreachable
///      strategy. There is one encoder, and the account owns the result of it.
///
///      `useTransferFromAndAquaPush` means the *taker* approves the router, which then pushes into
///      Aqua on the maker's behalf. That is the flag a page wants: a taker with an ordinary ERC-20
///      approval and no Aqua balance of its own. It also means the `taker` inside the taker traits
///      is the address the router pulls from, which is why a wrong one is worth stopping for.
contract SwapScript is Addresses {
    /// @dev `forge script`'s own default sender. Reaching a swap with this in the taker traits
    ///      means the router would try to pull tokens from an address nobody controls.
    address internal constant FORGE_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    function run() external view {
        address deskAddress = vm.envAddress("DESK");
        address taker = vm.envOr("TAKER", msg.sender);
        require(
            taker != FORGE_DEFAULT_SENDER,
            "set TAKER=0x... (or --sender): it goes into the taker traits and the router pulls from it"
        );

        DeskParams memory p = _params(deskAddress);
        bool sellBase = vm.envOr("SELL_BASE", false);
        (address tokenIn, address tokenOut) = sellBase ? (p.base, p.quote) : (p.quote, p.base);
        // Exact-in, so the taker's leg *is* `amount`: the mint and the approve need no quote first,
        // and the only thing the quote would tell us is the price, which is step 1 below.
        uint256 amount = vm.envOr("AMOUNT", uint256(1e6));

        bytes memory takerData = _takerData(taker);
        ISwapVM.Order memory order = _order(deskAddress);

        console.log("desk    ", deskAddress);
        console.log("taker   ", taker);
        console.log("in      ", amount, _symbol(tokenIn), tokenIn);
        console.log("out     ", _symbol(tokenOut), tokenOut);
        console.log("");
        console.log("The book is not readable from a forge fork, so nothing here is executed.");
        console.log("Run these against the node, in order:");
        console.log("");

        string memory rpc = vm.envOr("CAST_RPC", string("$HYPEREVM_RPC_URL"));
        string memory auth = vm.envOr("CAST_AUTH", string("--account $DEPLOYER_ACCOUNT"));
        // Pricing, kept separate from auth so a caller can pin it without pretending it is a
        // credential. `--legacy` matters on 999: cast otherwise builds a 1559 transaction, takes
        // maxPriorityFeePerGas from the node's own suggestion, and the node then rejects it as
        // higher than the maxFeePerGas it was given.
        string memory gas = vm.envOr("CAST_GAS", string("--legacy --gas-price 0.15gwei"));

        console.log("# 1. what the desk pays, priced off the live book");
        console.log(
            string.concat(
                "cast call ",
                vm.toString(router()),
                " ",
                vm.toString(abi.encodeCall(ISwapVM.quote, (order, tokenIn, tokenOut, amount, takerData))),
                " --rpc-url ",
                rpc
            )
        );
        console.log("#    decode with: cast abi-decode 'quote()(uint256,uint256,bytes32)' <output>");
        console.log("");

        if (_isDemoToken(tokenIn)) {
            console.log("# 2. mint the mock leg (public on DemoToken, and only on the demo pair)");
            console.log(
                string.concat(
                    "cast send ",
                    vm.toString(tokenIn),
                    " 'mint(address,uint256)' ",
                    vm.toString(taker),
                    " ",
                    vm.toString(amount),
                    " --rpc-url ",
                    rpc,
                    " ",
                    auth,
                    " ",
                    gas
                )
            );
            console.log("");
        }

        console.log("# 3. approve the router for exactly the amount going in");
        console.log(
            string.concat(
                "cast send ",
                vm.toString(tokenIn),
                " 'approve(address,uint256)' ",
                vm.toString(router()),
                " ",
                vm.toString(amount),
                " --rpc-url ",
                rpc,
                " ",
                auth,
                " ",
                gas
            )
        );
        console.log("");

        console.log("# 4. swap");
        console.log(
            string.concat(
                "cast send ",
                vm.toString(router()),
                " ",
                vm.toString(abi.encodeCall(ISwapVM.swap, (order, tokenIn, tokenOut, amount, takerData))),
                " --rpc-url ",
                rpc,
                " ",
                auth,
                " ",
                gas
            )
        );
    }

    /// @dev Exact-in, no threshold, no callbacks. A page sets a threshold; a command a human pastes
    ///      after reading step 1's price does not need one, and leaving it out keeps what is being
    ///      demonstrated — the router dispatching the maker's program — free of anything else.
    function _takerData(address taker) private pure returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: taker,
                isExactIn: true,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: true,
                threshold: "",
                to: address(0),
                deadline: 0,
                hasPreTransferInCallback: false,
                hasPreTransferOutCallback: false,
                preTransferInHookData: "",
                postTransferInHookData: "",
                preTransferOutHookData: "",
                postTransferOutHookData: "",
                preTransferInCallbackData: "",
                preTransferOutCallbackData: "",
                instructionsArgs: "",
                signature: ""
            })
        );
    }

    /// @dev Staticcalls rather than a typed call so a wrong DESK is a sentence, not a decode panic.
    function _order(address desk) private view returns (ISwapVM.Order memory) {
        (bool ok, bytes memory ret) = desk.staticcall(abi.encodeWithSignature("order()"));
        require(ok && ret.length != 0, "desk.order() reverted: is DESK a DeskAccount, and is it open?");
        return abi.decode(ret, (ISwapVM.Order));
    }

    function _params(address desk) private view returns (DeskParams memory p) {
        (bool ok, bytes memory ret) = desk.staticcall(abi.encodeWithSignature("params()"));
        require(ok && ret.length != 0, "desk.params() reverted: is DESK a DeskAccount?");
        return abi.decode(ret, (DeskParams));
    }

    function _symbol(address token) private view returns (string memory) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("symbol()"));
        return ok && ret.length >= 64 ? abi.decode(ret, (string)) : "?";
    }

    /// @dev Only the demo pair can be minted, and only where one is deployed. A deployment file
    ///      without a demo pair is a real state — the mainnet desk over UBTC/USDT0 — so the missing
    ///      key is checked rather than caught.
    function _isDemoToken(address token) private view returns (bool) {
        string memory json = vm.readFile(deploymentsPath());
        if (!vm.keyExistsJson(json, ".demoBase") || !vm.keyExistsJson(json, ".demoQuote")) return false;
        return token == vm.parseJsonAddress(json, ".demoBase") || token == vm.parseJsonAddress(json, ".demoQuote");
    }
}
