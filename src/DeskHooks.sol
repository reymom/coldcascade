// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IMakerHooks } from "@1inch/swap-vm/src/interfaces/IMakerHooks.sol";

import { ICoreReader, Book } from "./interfaces/ICoreReader.sol";
import { IDeskAccount } from "./interfaces/IDeskAccount.sol";
import { IMapOracle, LiquidationMap } from "./interfaces/IMapOracle.sol";
import { DeskParams, DeskParamsLib } from "./libs/DeskParams.sol";
import { Regime, RegimeLib } from "./libs/Regime.sol";

/// @notice The desk's post-transfer-out maker hook. Runs in the swap path only, after tokenOut has
///         moved, and emits the fill together with the book it was filled against. That is how the
///         L1 book becomes EVM logs, and how a markout can be computed later from indexed data alone.
/// @dev The quote path never touches this contract, so CoreQuote stays `view`.
///      The hedge leg, when unlocked, branches from postTransferOut.
///
///      One hook contract serves every desk. It holds no per-desk state: the maker's parameters
///      arrive as `makerData`, which is the same packed `DeskParams` the program carries.
///
///      **Nothing after the transfer is allowed to fail the transfer.** By the time this runs the
///      taker has been paid and the maker has been pulled; a revert here would unwind a swap that
///      already priced correctly, so every read is fail-soft. A book that could not be read is
///      emitted as four zeros, which an indexer can see and a markout can skip. It is not
///      interpolated and it is not a reason to reject the fill.
contract DeskHooks is IMakerHooks {
    using DeskParamsLib for bytes;

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

    /// @notice The maker is a contract and its `onFill` did not succeed. The fill stood anyway.
    /// @dev Emitted rather than swallowed: a desk whose hedge is silently failing every fill is a
    ///      desk whose owner needs to know, and it is one subgraph query.
    event MakerCallFailed(bytes32 indexed orderHash, address indexed maker);

    error OnlyRouter(address caller);

    /// @notice Gas forwarded to a maker account's `onFill`.
    /// @dev The cap is what makes "a hedge can never fail a fill" a bound and not a hope: without
    ///      it a maker could burn the taker's whole budget and the 1/64 EIP-150 leaves behind might
    ///      not finish the transaction. It is also a taker cost, so it is a stated number.
    ///
    ///      Today's `DeskAccount.onFill` costs 5 797 gas with the hedge armed and firing, measured
    ///      2026-09-05 by `test_onFill_costsWhatTheCapAllowsFor`. The ceiling has room for the
    ///      CoreWriter leg it grows into -- HyperCore's docs put `sendRawAction` at ~47 000 gas
    ///      with 25 000 burned, `[UNVERIFIED]` against the chain until the 999 probe on 2026-09-07.
    uint256 internal constant ONFILL_GAS_CAP = 250_000;

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

    /// @param makerData The packed DeskParams the program carries, so the hook knows the perp index
    ///        and the map oracle without storage.
    /// @dev `feeOut` is the protocol fee the router took on top of `amountOut`. A desk program sets
    ///      no protocol fee, so it is structurally zero here and is not widened into the event.
    function postTransferOut(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256,
        bytes32 orderHash,
        bytes calldata makerData,
        bytes calldata
    ) external {
        if (msg.sender != ROUTER) revert OnlyRouter(msg.sender);

        DeskParams memory p = makerData.decode();
        Book memory book = _book(p.perpIndex);
        Regime memory r = RegimeLib.classify(book, _map(p.mapOracle, p.perpIndex), p, block.timestamp);

        emit Fill(
            orderHash,
            maker,
            taker,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            book.bid,
            book.ask,
            book.mark,
            book.oracle,
            r.mapBelow,
            r.mapAbove
        );

        // The maker may be a contract that wants to cover what it just absorbed. By here the taker
        // has been paid and the maker has been pulled, so this call is allowed to do nothing and
        // is not allowed to do anything else: capped gas, and every failure caught. An EOA maker
        // -- the control strategy is one -- is not called at all.
        if (maker.code.length != 0) {
            try IDeskAccount(maker).onFill{ gas: ONFILL_GAS_CAP }(
                orderHash, tokenIn, tokenOut, amountIn, amountOut, book, r.lean
            ) { } catch {
                emit MakerCallFailed(orderHash, maker);
            }
        }
    }

    /// @dev The quote that priced this fill read the same book in the same transaction, so a read
    ///      that answered then answers now. The catch is here for the one case that is not the
    ///      book's fault — a reader swapped for one that reverts — and it costs nothing.
    function _book(uint32 perpIndex) private view returns (Book memory book) {
        try READER.read(perpIndex) returns (Book memory fresh) {
            return fresh;
        } catch {
            return book;
        }
    }

    /// @dev Same rule as the quote's: a missing, unset or reverting map is (0, 0), never an error.
    function _map(address mapOracle, uint32 perpIndex) private view returns (LiquidationMap memory empty) {
        if (mapOracle == address(0)) return empty;
        try IMapOracle(mapOracle).map(perpIndex) returns (LiquidationMap memory fresh) {
            return fresh;
        } catch {
            return empty;
        }
    }
}
