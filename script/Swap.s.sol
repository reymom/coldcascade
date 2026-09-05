// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { console } from "forge-std/console.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { Addresses } from "./base/Addresses.sol";
import { CoreQuote } from "../src/CoreQuote.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { DeskAccount } from "../src/DeskAccount.sol";
import { DeskParams } from "../src/libs/DeskParams.sol";
import { Side } from "../src/libs/Regime.sol";

/// @notice One swap through the official SwapVM router, against a desk that is already shipped.
///         The explorer link in the README, and the same three calls the console's Take button
///         makes.
///
///         DESK=0x… SELL_BASE=false AMOUNT=25000000 \
///           forge script script/Swap.s.sol --rpc-url hyperevm --account $DEPLOYER_ACCOUNT \
///           --sender $DEPLOYER --broadcast
///
/// @dev The order is read back from the account with `order()` rather than rebuilt here. Aqua keys
///      a strategy by the hash of the exact bytes that were shipped, so an order assembled a second
///      time from the same parameters is one wrong byte away from being a different, unreachable
///      strategy. There is one encoder, and the account owns the result of it.
///
///      `useTransferFromAndAquaPush` means the *taker* approves the router, which then pushes into
///      Aqua on the maker's behalf. That is the flag a page wants: a taker with an ordinary ERC-20
///      approval and no Aqua balance of its own.
contract SwapScript is Addresses {
    using SafeERC20 for IERC20;

    function run() external {
        DeskAccount desk = DeskAccount(vm.envAddress("DESK"));
        DeskParams memory p = desk.params();
        CoreQuote coreQuote = CoreQuote(readAddress("coreQuote"));

        // The desk's bid side is the taker selling base. Sell base to be bought, or buy it.
        bool sellBase = vm.envOr("SELL_BASE", false);
        address tokenIn = sellBase ? p.base : p.quote;
        uint256 amount = vm.envOr("AMOUNT", uint256(1e6));

        (uint256 bidPx, uint256 askPx, Side lean) = coreQuote.bounds(p);
        console.log("desk bid/ask (raw L1 units)", bidPx, askPx);
        console.log("lean", uint256(uint8(lean)));

        ISwapVM.Order memory order = desk.order();
        bytes memory takerData = _takerData(msg.sender, sellBase, p);

        (uint256 quotedIn, uint256 quotedOut,) = ISwapVM(router()).quote(order, amount, takerData);
        console.log("quote in/out", quotedIn, quotedOut);

        vm.startBroadcast();
        if (tokenIn == readAddress("demoBase") || tokenIn == readAddress("demoQuote")) {
            DemoToken(tokenIn).mint(msg.sender, quotedIn);
        }
        IERC20(tokenIn).forceApprove(router(), quotedIn);
        (uint256 amountIn, uint256 amountOut, bytes32 orderHash) = ISwapVM(router()).swap(order, amount, takerData);
        vm.stopBroadcast();

        console.log("filled in/out", amountIn, amountOut);
        console.logBytes32(orderHash);
    }

    /// @dev Exact-in, no threshold, no callbacks. A page sets a threshold; a script that is its own
    ///      counterparty does not need one, and leaving it out keeps what is being demonstrated —
    ///      the router dispatching the maker's program — free of anything else.
    function _takerData(address taker, bool sellBase, DeskParams memory p) private pure returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: taker,
                isExactIn: true,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: true,
                isAToB: sellBase == (p.base < p.quote),
                allowPartialFill: false,
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
}
