// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IMakerHooks } from "@1inch/swap-vm/src/interfaces/IMakerHooks.sol";

import { ICoreReader } from "./interfaces/ICoreReader.sol";
import { IMapOracle } from "./interfaces/IMapOracle.sol";

/// @notice The desk's post-transfer-out maker hook. Runs in the swap path only, after tokenOut has
///         moved, and emits the fill together with the book it was filled against. That is how the
///         L1 book becomes EVM logs, and how a markout can be computed later from indexed data alone.
/// @dev The quote path never touches this contract, so CoreQuote stays `view`.
///      The hedge leg, when unlocked, branches from postTransferOut.
contract DeskHooks is IMakerHooks {
    event Fill(
        bytes32 indexed orderHash,
        address indexed maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint64 bid,
        uint64 ask,
        uint64 mark,
        uint64 oracle,
        uint128 mapBelow,
        uint128 mapAbove
    );

    error OnlyRouter(address caller);

    address public immutable ROUTER;
    ICoreReader public immutable READER;

    constructor(address router, ICoreReader reader) {
        ROUTER = router;
        READER = reader;
    }

    function preTransferIn(address, address, address, address, uint256, uint256, bytes32, bytes calldata, bytes calldata)
        external
    { }

    function postTransferIn(
        address, address, address, address, uint256, uint256, uint256, bytes32, bytes calldata, bytes calldata
    ) external { }

    function preTransferOut(address, address, address, address, uint256, uint256, bytes32, bytes calldata, bytes calldata)
        external
    { }

    /// @param makerData abi.encode(DeskParams) — the same bytes the program carries, so the hook
    ///        knows the perp index and the map oracle without storage.
    function postTransferOut(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeOut,
        bytes32 orderHash,
        bytes calldata makerData,
        bytes calldata takerData
    ) external {
        revert("todo");
    }
}
