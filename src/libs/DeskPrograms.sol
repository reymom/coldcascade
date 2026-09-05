// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { XYCSwap } from "@1inch/swap-vm/src/instructions/XYCSwap.sol";
import { Extruction } from "@1inch/swap-vm/src/instructions/Extruction.sol";
import { Salt } from "@1inch/swap-vm/src/instructions/Controls.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";

import { DeskParams, DeskParamsLib } from "./DeskParams.sol";

/// @notice The one place that concatenates. Order is load-bearing: the curve fills the leg,
///         then CoreQuote bounds it. The control strategy is the same order without the bound.
/// @dev Every byte here comes out of 1inch's own builders — `XYCSwap.build`, `Extruction.build`,
///      `Salt.build`, `MakerTraitsLib.build`. Nothing about the encoding is ours, which is the
///      point: a program this library emits is one the deployed router already knows how to run.
library DeskPrograms {
    using DeskParamsLib for DeskParams;

    /// @return XYCSwap || Extruction(coreQuote, abi.encode(p))
    function desk(address coreQuote, DeskParams memory p) internal pure returns (bytes memory) {
        return bytes.concat(XYCSwap.build(), Extruction.build(coreQuote, p.encode()));
    }

    /// @return XYCSwap || Extruction(coreQuote, abi.encode(p)) || Salt(salt)
    /// @dev Aqua keys a strategy by `keccak256(strategy)` and refuses to ship the same hash twice,
    ///      even after a dock. A desk that reopens with the parameters it already had is the normal
    ///      case, so every account ships with a salt rather than discovering this at the second open.
    function deskWithSalt(address coreQuote, DeskParams memory p, bytes32 salt)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(desk(coreQuote, p), Salt.build(abi.encodePacked(salt)));
    }

    /// @return XYCSwap || Salt(salt) — the other line on the screen
    function control(bytes32 salt) internal pure returns (bytes memory) {
        return bytes.concat(XYCSwap.build(), Salt.build(abi.encodePacked(salt)));
    }

    /// @notice An Aqua order (useAquaInsteadOfSignature) with the desk hook on post-transfer-out.
    /// @param hooks The single `DeskHooks` instance, or zero for a strategy that emits no Fill —
    ///        the control ships that way so the two lines differ by the quote and nothing else.
    /// @dev `postTransferOutData` is the same `abi.encode(p)` the program carries, so the hook reads
    ///      the perp index and the map oracle out of calldata instead of storage.
    function order(address maker, address hooks, bytes memory program, DeskParams memory p)
        internal
        pure
        returns (ISwapVM.Order memory)
    {
        (address tokenA, address tokenB) = p.base < p.quote ? (p.base, p.quote) : (p.quote, p.base);
        bool hasHook = hooks != address(0) && hooks != maker;

        return MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: maker,
                receiver: address(0), // the maker itself: an account's fills come back to the account
                tokenA: tokenA,
                tokenB: tokenB,
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: true,
                allowZeroAmountIn: false,
                hasPreTransferInHook: false,
                hasPostTransferInHook: false,
                hasPreTransferOutHook: false,
                hasPostTransferOutHook: hasHook,
                preTransferInTarget: address(0),
                preTransferInData: "",
                postTransferInTarget: address(0),
                postTransferInData: "",
                preTransferOutTarget: address(0),
                preTransferOutData: "",
                postTransferOutTarget: hasHook ? hooks : address(0),
                postTransferOutData: hasHook ? p.encode() : bytes(""),
                program: program
            })
        );
    }

    /// @notice What ship() must receive, byte for byte: Aqua hashes the raw calldata and SwapVM
    ///         hashes keccak256(abi.encode(order)). Anything else ships an unreachable strategy.
    function strategyBytes(ISwapVM.Order memory o) internal pure returns (bytes memory) {
        return abi.encode(o);
    }

    /// @notice The two tokens in the order Aqua's `ship` and `dock` want them.
    /// @dev `dock` requires the token count it is given to equal the count `ship` recorded, so the
    ///      two calls have to agree on the array. One function, both call sites.
    function tokens(DeskParams memory p) internal pure returns (address[] memory list) {
        list = new address[](2);
        (list[0], list[1]) = (p.base, p.quote);
    }
}
