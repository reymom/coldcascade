// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Book } from "./ICoreReader.sol";
import { Side } from "../libs/Regime.sol";

/// @notice What `DeskHooks` calls on a maker that is a contract, after the fill is already settled.
/// @dev The call is optional in both directions: the hook only makes it when the maker has code,
///      and it is wrapped so that whatever the account does with it — including running out of gas
///      — cannot unwind the swap. An account that does not want the callback simply reverts.
interface IDeskAccount {
    /// @param book The four L1 words the fill was priced against, read in the same transaction.
    /// @param lean Which side of the desk was absorbing when it filled, or None.
    function onFill(
        bytes32 orderHash,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        Book calldata book,
        Side lean
    ) external;
}
