// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";
import { IStaticExtruction, IExtruction } from "@1inch/swap-vm/src/instructions/Extruction.sol";

import { ICoreReader, Book } from "./interfaces/ICoreReader.sol";
import { DeskParams, DeskParamsLib } from "./libs/DeskParams.sol";
import { Regime, Side, RegimeLib } from "./libs/Regime.sol";

/// @title CoreQuote
/// @notice The Extruction target of a desk program: `XYCSwap || Extruction(CoreQuote, DeskParams)`.
///         Bounds the curve's leg by Hyperliquid's own book, read in the same call, and moves the
///         absorbing side inside the L1 spread when the book dislocates from oracle or when a fresh
///         liquidation map says mark is walking into forced flow.
/// @dev One code path for quote and swap. `view` in both, because a precompile read is pure in both.
///      No storage, no owner, no upgrade. The maker's parameters arrive in `args`, frozen at ship().
///      SwapVM guarantees the taker-specified leg is untouched, so a fill the inventory band cannot
///      take reverts rather than being resized.
contract CoreQuote is IStaticExtruction, IExtruction {
    using DeskParamsLib for bytes;

    /// @notice Where the book comes from. CorePrecompiles when nested STATICCALL reaches the node,
    ///         BookCache otherwise. Immutable either way.
    ICoreReader public immutable READER;

    error CrossedBook(uint64 bid, uint64 ask);
    error WrongPair(address tokenIn, address tokenOut);
    error InventoryBand(uint256 baseAfter, uint128 minBase, uint128 maxBase);

    constructor(ICoreReader reader) {
        READER = reader;
    }

    /// @inheritdoc IStaticExtruction
    /// @dev Reads the book, classifies the regime, bounds or leans the curve-filled leg, checks the
    ///      inventory band. Returns nextPC unchanged and chops nothing from takerData.
    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata takerData
    )
        external
        view
        override(IStaticExtruction, IExtruction)
        returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegisters memory updatedSwap)
    {
        revert("todo");
    }

    /// @notice The regime this desk would quote under right now. What the page and the keeper read.
    function regime(DeskParams calldata p) external view returns (Regime memory) {
        revert("todo");
    }

    /// @notice The desk's own bid and ask in quote units per base unit, next to L1's.
    function bounds(DeskParams calldata p) external view returns (uint256 bidPx, uint256 askPx, Side lean) {
        revert("todo");
    }
}
