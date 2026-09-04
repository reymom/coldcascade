// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ICoreWriter } from "./interfaces/ICoreWriter.sol";

/// @notice Absorb spot where you can see, hedge on the perp where you can see: after a stress-side
///         fill the desk opens the opposite perp position on HyperCore through CoreWriter, same tx.
/// @dev Gated. Nothing here runs before the Tue-8 death metric passes and three things are checked:
///      the contract can hold a funded HyperCore perps account, the few-second order delay is
///      acceptable at a 15-minute horizon, and the gas after the burn is what the docs say.
contract HedgeLeg {
    ICoreWriter public constant CORE_WRITER = ICoreWriter(0x3333333333333333333333333333333333333333);

    error Gated();

    function hedge(uint32 perpIndex, bool isShort, uint64 sizeRaw) external {
        revert("todo: gated on the tue-8 death metric");
    }
}
