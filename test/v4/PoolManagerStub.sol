// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    PoolKey,
    SwapParams,
    IHooks,
    Hooks,
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    BalanceDelta,
    BalanceDeltaLibrary,
    toBalanceDelta,
    V4SafeCast
} from "./V4Frame.sol";

/// @notice What `PoolManager.swap` does between receiving a swap and accounting it, reduced to the
///         arithmetic and nothing else: `Hooks.beforeSwap` — the permission bits read off the hook's
///         address, the 96-byte response check, the specified delta folded into the amount, the
///         exact-in/exact-out flip check — then `Pool.swap`'s early return on a zero amount, then
///         `Hooks.afterSwap`'s fold of the hook's delta into the swapper's. No lock, no `settle`, no
///         ERC-6909: a delta is the accounting there and it is the accounting here.
/// @dev Copied from `Uniswap/v4-core` at `main`, 2026-09-08: `libraries/Hooks.sol` (`beforeSwap`,
///      `afterSwap`), `libraries/Pool.sol` (`swap`, the first line), `PoolManager.sol` (`swap`).
///      Two liberties, both named: a hook's revert bubbles up raw here where v4 wraps it in
///      `WrappedError`, so a test can `expectRevert` the rule's own error; and the curve is a
///      constant product on two seeded reserves standing in for the concentrated-liquidity engine.
///      Nothing asserted about the hook depends on the curve's shape — the hook under test zeroes
///      the amount the curve sees. The curve exists so that a hook *without* the returns-delta bit
///      has something to be ignored in favour of.
contract PoolManagerStub {
    using Hooks for IHooks;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    struct Result {
        int256 amountToSwap;          // what the curve was asked for, after the hook's specified delta
        BalanceDelta swapDelta;       // what the curve answered
        BalanceDelta hookDelta;       // what the hook took and gave
        BalanceDelta swapperDelta;    // what the swapper is accounted: swapDelta - hookDelta
    }

    error SwapAmountCannotBeZero();
    error UnsupportedPermission(uint160 flag);
    error CurveExhausted(uint256 wanted, uint256 reserve);

    /// @dev The stand-in curve, in currency0 / currency1 order.
    uint256 public reserve0;
    uint256 public reserve1;

    function seed(uint256 r0, uint256 r1) external {
        reserve0 = r0;
        reserve1 = r1;
    }

    /// @notice `PoolManager.swap`, as far as the deltas.
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (Result memory r)
    {
        if (params.amountSpecified == 0) revert SwapAmountCannotBeZero();
        // afterSwap is not reproduced; the hook under test does not set the bit, so say so loudly if one does.
        if (key.hooks.hasPermission(Hooks.AFTER_SWAP_FLAG)) revert UnsupportedPermission(Hooks.AFTER_SWAP_FLAG);

        BeforeSwapDelta hookReturn;
        (r.amountToSwap, hookReturn) = _beforeSwap(key, params, hookData);
        r.swapDelta = _curve(params.zeroForOne, r.amountToSwap);
        (r.swapperDelta, r.hookDelta) = _afterSwap(params, r.swapDelta, hookReturn);
    }

    /// @dev `Hooks.beforeSwap`, minus the lp fee override: the pool here has a static fee of zero,
    ///      and for a static-fee pool the wrapper ignores the third word anyway.
    function _beforeSwap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        private
        returns (int256 amountToSwap, BeforeSwapDelta hookReturn)
    {
        amountToSwap = params.amountSpecified;
        if (!key.hooks.hasPermission(Hooks.BEFORE_SWAP_FLAG)) return (amountToSwap, hookReturn);

        (bool ok, bytes memory result) =
            address(key.hooks).call(abi.encodeCall(IHooks.beforeSwap, (msg.sender, key, params, hookData)));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        // callHook: the selector is the receipt; beforeSwap: a bytes4, a 32-byte delta and a fee are 96 bytes.
        if (result.length < 32 || bytes4(result) != IHooks.beforeSwap.selector) revert Hooks.InvalidHookResponse();
        if (result.length != 96) revert Hooks.InvalidHookResponse();

        // skip this logic for the case where the hook return is 0
        if (key.hooks.hasPermission(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)) {
            (, int256 delta,) = abi.decode(result, (bytes4, int256, uint24));
            hookReturn = BeforeSwapDelta.wrap(delta);

            // any return in unspecified is passed to the afterSwap hook for handling
            int128 hookDeltaSpecified = hookReturn.getSpecifiedDelta();

            // Update the swap amount according to the hook's return, and check that the swap type doesn't change (exact input/output)
            if (hookDeltaSpecified != 0) {
                bool exactInput = amountToSwap < 0;
                amountToSwap += hookDeltaSpecified;
                if (exactInput ? amountToSwap > 0 : amountToSwap < 0) revert Hooks.HookDeltaExceedsSwapAmount();
            }
        }
    }

    /// @dev `Pool.swap`'s first line — `if (params.amountSpecified == 0) return (ZERO_DELTA, ...)` —
    ///      and, when the amount is not zero, a constant product in place of the tick walk. Same
    ///      formula as SwapVM's `XYCSwap`, so the stale-curve number below is the README's.
    function _curve(bool zeroForOne, int256 amountToSwap) private returns (BalanceDelta) {
        if (amountToSwap == 0) return BalanceDeltaLibrary.ZERO_DELTA;

        (uint256 rIn, uint256 rOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 amountIn;
        uint256 amountOut;
        if (amountToSwap < 0) {
            amountIn = uint256(-amountToSwap);
            amountOut = amountIn * rOut / (rIn + amountIn);
        } else {
            amountOut = uint256(amountToSwap);
            if (amountOut >= rOut) revert CurveExhausted(amountOut, rOut);
            amountIn = Math.ceilDiv(amountOut * rIn, rOut - amountOut);
        }
        (reserve0, reserve1) = zeroForOne ? (rIn + amountIn, rOut - amountOut) : (rOut - amountOut, rIn + amountIn);

        // The swapper pays the input currency and is owed the output one.
        int128 paid = -V4SafeCast.toInt128(amountIn);
        int128 got = V4SafeCast.toInt128(amountOut);
        return zeroForOne ? toBalanceDelta(paid, got) : toBalanceDelta(got, paid);
    }

    /// @dev `Hooks.afterSwap` for a hook without the AFTER_SWAP bit: only the beforeSwap return is
    ///      folded, mapped onto (amount0, amount1) by which currency was the specified one.
    function _afterSwap(SwapParams memory params, BalanceDelta swapDelta, BeforeSwapDelta beforeSwapHookReturn)
        private
        pure
        returns (BalanceDelta, BalanceDelta)
    {
        int128 hookDeltaSpecified = beforeSwapHookReturn.getSpecifiedDelta();
        int128 hookDeltaUnspecified = beforeSwapHookReturn.getUnspecifiedDelta();

        BalanceDelta hookDelta;
        if (hookDeltaUnspecified != 0 || hookDeltaSpecified != 0) {
            hookDelta = (params.amountSpecified < 0 == params.zeroForOne)
                ? toBalanceDelta(hookDeltaSpecified, hookDeltaUnspecified)
                : toBalanceDelta(hookDeltaUnspecified, hookDeltaSpecified);

            // the caller has to pay for (or receive) the hook's delta
            swapDelta = swapDelta - hookDelta;
        }
        return (swapDelta, hookDelta);
    }
}
