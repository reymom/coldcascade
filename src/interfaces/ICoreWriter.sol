// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Hyperliquid's system contract for sending actions from HyperEVM to HyperCore.
///         Lives at 0x3333333333333333333333333333333333333333 on chain 999.
/// @dev Selector 0x17938e13 checked against the deployed bytecode on 2026-09-04.
///      Action payload layouts are not encoded here yet.
interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}
