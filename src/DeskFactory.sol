// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { DeskAccount } from "./DeskAccount.sol";
import { DeskParams } from "./libs/DeskParams.sol";

/// @notice Opens a desk: one transaction deploys the clone, moves the maker's two tokens into it,
///         approves Aqua and ships the strategy. The factory holds nothing and owns nothing — the
///         tokens go from the maker straight to the account, and the account's owner is the caller.
/// @dev EIP-1167 minimal proxies, so a desk costs a few tens of thousands of gas rather than a
///      deployment. Every clone shares the implementation's immutables: the same Aqua, the same
///      official router, the same `CoreQuote`, the same `DeskHooks`.
contract DeskFactory {
    using SafeERC20 for IERC20;

    /// @notice The desk directory, as far as the chain is concerned. One event per desk, carrying
    ///         the address a name resolves to and the strategy a swap reaches.
    event DeskOpened(
        address indexed desk, address indexed owner, string label, bytes32 strategyHash, DeskParams params
    );

    address public immutable IMPLEMENTATION;

    constructor(IAqua aqua, address router, address coreQuote, address hooks) {
        IMPLEMENTATION = address(new DeskAccount(aqua, router, coreQuote, hooks, address(this)));
    }

    /// @notice Open a desk owned by the caller.
    /// @dev The caller approves this contract for both legs beforehand; the transfer is
    ///      maker → account, so the factory is never a custodian even for one call.
    function open(string calldata label, DeskParams calldata p, uint256 amountBase, uint256 amountQuote)
        external
        returns (address desk, bytes32 strategyHash)
    {
        desk = Clones.clone(IMPLEMENTATION);

        if (amountBase != 0) IERC20(p.base).safeTransferFrom(msg.sender, desk, amountBase);
        if (amountQuote != 0) IERC20(p.quote).safeTransferFrom(msg.sender, desk, amountQuote);

        strategyHash = DeskAccount(desk).initialize(msg.sender, label, p, amountBase, amountQuote);
        emit DeskOpened(desk, msg.sender, label, strategyHash, p);
    }
}
