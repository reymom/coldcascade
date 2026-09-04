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
library DeskPrograms {
    using DeskParamsLib for DeskParams;

    /// @return XYCSwap || Extruction(coreQuote, abi.encode(p))
    function desk(address coreQuote, DeskParams memory p) internal pure returns (bytes memory) {
        revert("todo");
    }

    /// @return XYCSwap || Extruction(coreQuote, abi.encode(p)) || Salt(salt)
    function deskWithSalt(address coreQuote, DeskParams memory p, bytes32 salt) internal pure returns (bytes memory) {
        revert("todo");
    }

    /// @return XYCSwap || Salt(salt) — the other line on the screen
    function control(bytes32 salt) internal pure returns (bytes memory) {
        revert("todo");
    }

    /// @notice An Aqua order (useAquaInsteadOfSignature) with the desk hook on post-transfer-out.
    function order(address maker, address hooks, bytes memory program, DeskParams memory p)
        internal
        pure
        returns (ISwapVM.Order memory)
    {
        revert("todo");
    }

    /// @notice What ship() must receive, byte for byte: Aqua hashes the raw calldata and SwapVM
    ///         hashes keccak256(abi.encode(order)). Anything else ships an unreachable strategy.
    function strategyBytes(ISwapVM.Order memory o) internal pure returns (bytes memory) {
        return abi.encode(o);
    }
}
