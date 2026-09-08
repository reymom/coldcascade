// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";

import { CoreQuote } from "../../src/CoreQuote.sol";
import { DeskParams, DeskParamsLib } from "../../src/libs/DeskParams.sol";
import { Currency, PoolKey, SwapParams, IHooks, Hooks, BeforeSwapDelta, toBeforeSwapDelta, V4SafeCast } from "./V4Frame.sol";

/// @title CoreQuoteHook
/// @notice The desk's quote as a Uniswap v4 `beforeSwap` hook. Test-only, and not by choice: v4's
///         PoolManager is deployed on 24 chains and HyperEVM is not among them (deployments page,
///         read 2026-09-08), and HyperEVM is the one chain where the book this quote reads exists.
///         So the contract compiles, its tests pass, and there is nowhere it would be true. That is
///         the finding `FEEDBACK.md` reports; this file is the evidence that the *interface* is not
///         what is missing.
/// @dev The rule is not rewritten. `CoreQuote.extruction` is the rule — the same bytes deployed on
///      999 — and this contract is the frame around it: v4 says which currency is specified and
///      with what sign, the hook turns that into the register the Extruction expects, and turns the
///      answer back into a `BeforeSwapDelta`. The specified delta is exactly `-amountSpecified`,
///      which makes `amountToSwap` zero and the pool's curve a bystander; the unspecified delta is
///      the maker's leg. A hook with the returns-delta bit is the maker and the pool is where it
///      settles; a hook without it is at most a fee lever — `test_withoutTheReturnsDeltaBit…`.
///
///      `view`, as the Extruction is. SwapVM quotes through STATICCALL and declares
///      `IStaticExtruction.extruction` `external view`; v4's `IHooks.beforeSwap` is not `view`, and
///      a quoter learns the price by simulating the swap. The rule needs no state to answer, so
///      the hook takes none. Solidity allows the override to be stricter, and it is.
///
///      The maker's parameters are written once, at construction, and there is no setter — the
///      closest a hook comes to Aqua hashing the strategy at `ship()`. Inventory is this contract's
///      own token balances, which is what Aqua's virtual balance is to the desk: `_requireBand`
///      reads them through the registers exactly as it reads Aqua's.
contract CoreQuoteHook is IHooks {
    /// @dev The two address bits this hook needs. `beforeSwap` to be called at all; returns-delta
    ///      for the manager to read the answer rather than drop it.
    uint160 public constant PERMISSIONS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    /// @notice The rule, with its reader inside it.
    CoreQuote public immutable QUOTE;

    DeskParams internal _p;

    constructor(CoreQuote quote, DeskParams memory p) {
        QUOTE = quote;
        _p = p;
    }

    /// @notice The maker's commitment, frozen at construction.
    function params() external view returns (DeskParams memory) {
        return _p;
    }

    /// @inheritdoc IHooks
    /// @dev exact-in: `amountSpecified < 0` and the taker names the input; exact-out: the output.
    ///      The Extruction receives the taker's leg in its register and a curve register of zero,
    ///      which `CoreQuote` reads as "no curve preceded, the book is the whole quote" — the same
    ///      answer the NoOp of the pool's curve requires.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params_, bytes calldata)
        external
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactIn = params_.amountSpecified < 0;
        uint256 takerLeg = exactIn ? uint256(-params_.amountSpecified) : uint256(params_.amountSpecified);
        (address tokenIn, address tokenOut) = params_.zeroForOne
            ? (Currency.unwrap(key.currency0), Currency.unwrap(key.currency1))
            : (Currency.unwrap(key.currency1), Currency.unwrap(key.currency0));

        SwapQuery memory query = SwapQuery({
            orderHash: keccak256(abi.encode(key)),   // PoolIdLibrary.toId
            maker: address(this),
            taker: sender,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            isExactIn: exactIn
        });
        SwapRegisters memory regs = SwapRegisters({
            balanceIn: IERC20(tokenIn).balanceOf(address(this)),
            balanceOut: IERC20(tokenOut).balanceOf(address(this)),
            amountIn: exactIn ? takerLeg : 0,
            amountOut: exactIn ? 0 : takerLeg,
            amountNetPulled: 0
        });
        (,, SwapRegisters memory filled) = QUOTE.extruction(true, 0, query, regs, DeskParamsLib.encode(_p), "");
        uint256 makerLeg = exactIn ? filled.amountOut : filled.amountIn;

        // Take the specified leg off the curve entirely; owe or take the maker's leg in the other currency.
        int128 specified = V4SafeCast.toInt128(-params_.amountSpecified);
        int128 unspecified = exactIn ? -V4SafeCast.toInt128(makerLeg) : V4SafeCast.toInt128(makerLeg);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specified, unspecified), 0);
    }
}
