// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The part of Uniswap v4's vocabulary a `beforeSwap` hook is written against, copied from
///         `Uniswap/v4-core` at `main` on 2026-09-08 rather than installed. This repository's
///         dependency graph is pinned to what 1inch has deployed on chain 999 and a single `yarn add`
///         has already broken `forge build` once (see the README's build notes), so v4-core is not
///         added to it for the sake of a test. The types are verbatim; the interface is the one
///         callback this hook implements out of `IHooks`'s ten; the flags are the two it sets.
///
///         Sources, all under `src/` in v4-core: `types/Currency.sol`, `types/PoolKey.sol`,
///         `types/PoolOperation.sol`, `types/BeforeSwapDelta.sol`, `types/BalanceDelta.sol`,
///         `interfaces/IHooks.sol`, `libraries/Hooks.sol`.

// ---- types/Currency.sol ----

type Currency is address;

// ---- types/PoolKey.sol ----

/// @notice Returns the key for identifying a pool
struct PoolKey {
    /// @notice The lower currency of the pool, sorted numerically
    Currency currency0;
    /// @notice The higher currency of the pool, sorted numerically
    Currency currency1;
    /// @notice The pool LP fee, capped at 1_000_000. If the highest bit is 1, the pool has a dynamic fee and must be exactly equal to 0x800000
    uint24 fee;
    /// @notice Ticks that involve positions must be a multiple of tick spacing
    int24 tickSpacing;
    /// @notice The hooks of the pool
    IHooks hooks;
}

// ---- types/PoolOperation.sol ----

struct SwapParams {
    /// Whether to swap token0 for token1 or vice versa
    bool zeroForOne;
    /// The desired input amount if negative (exactIn), or the desired output amount if positive (exactOut)
    int256 amountSpecified;
    /// The sqrt price at which, if reached, the swap will stop executing
    uint160 sqrtPriceLimitX96;
}

// ---- types/BeforeSwapDelta.sol ----

// Return type of the beforeSwap hook.
// Upper 128 bits is the delta in specified tokens. Lower 128 bits is delta in unspecified tokens (to match the afterSwap hook)
type BeforeSwapDelta is int256;

// Creates a BeforeSwapDelta from specified and unspecified
function toBeforeSwapDelta(int128 deltaSpecified, int128 deltaUnspecified)
    pure
    returns (BeforeSwapDelta beforeSwapDelta)
{
    assembly ("memory-safe") {
        beforeSwapDelta := or(shl(128, deltaSpecified), and(sub(shl(128, 1), 1), deltaUnspecified))
    }
}

library BeforeSwapDeltaLibrary {
    /// @notice A BeforeSwapDelta of 0
    BeforeSwapDelta public constant ZERO_DELTA = BeforeSwapDelta.wrap(0);

    /// extracts int128 from the upper 128 bits of the BeforeSwapDelta
    /// returned by beforeSwap
    function getSpecifiedDelta(BeforeSwapDelta delta) internal pure returns (int128 deltaSpecified) {
        assembly ("memory-safe") {
            deltaSpecified := sar(128, delta)
        }
    }

    /// extracts int128 from the lower 128 bits of the BeforeSwapDelta
    /// returned by beforeSwap and afterSwap
    function getUnspecifiedDelta(BeforeSwapDelta delta) internal pure returns (int128 deltaUnspecified) {
        assembly ("memory-safe") {
            deltaUnspecified := signextend(15, delta)
        }
    }
}

// ---- types/BalanceDelta.sol ----

/// @dev Two `int128` values packed into a single `int256` where the upper 128 bits represent the amount0
/// and the lower 128 bits represent the amount1.
type BalanceDelta is int256;

using { add as +, sub as -, eq as ==, neq as != } for BalanceDelta global;
using BalanceDeltaLibrary for BalanceDelta global;

function toBalanceDelta(int128 _amount0, int128 _amount1) pure returns (BalanceDelta balanceDelta) {
    assembly ("memory-safe") {
        balanceDelta := or(shl(128, _amount0), and(sub(shl(128, 1), 1), _amount1))
    }
}

function add(BalanceDelta a, BalanceDelta b) pure returns (BalanceDelta) {
    int256 res0;
    int256 res1;
    assembly ("memory-safe") {
        let a0 := sar(128, a)
        let a1 := signextend(15, a)
        let b0 := sar(128, b)
        let b1 := signextend(15, b)
        res0 := add(a0, b0)
        res1 := add(a1, b1)
    }
    return toBalanceDelta(V4SafeCast.toInt128(res0), V4SafeCast.toInt128(res1));
}

function sub(BalanceDelta a, BalanceDelta b) pure returns (BalanceDelta) {
    int256 res0;
    int256 res1;
    assembly ("memory-safe") {
        let a0 := sar(128, a)
        let a1 := signextend(15, a)
        let b0 := sar(128, b)
        let b1 := signextend(15, b)
        res0 := sub(a0, b0)
        res1 := sub(a1, b1)
    }
    return toBalanceDelta(V4SafeCast.toInt128(res0), V4SafeCast.toInt128(res1));
}

function eq(BalanceDelta a, BalanceDelta b) pure returns (bool) {
    return BalanceDelta.unwrap(a) == BalanceDelta.unwrap(b);
}

function neq(BalanceDelta a, BalanceDelta b) pure returns (bool) {
    return BalanceDelta.unwrap(a) != BalanceDelta.unwrap(b);
}

/// @notice Library for getting the amount0 and amount1 deltas from the BalanceDelta type
library BalanceDeltaLibrary {
    /// @notice A BalanceDelta of 0
    BalanceDelta public constant ZERO_DELTA = BalanceDelta.wrap(0);

    function amount0(BalanceDelta balanceDelta) internal pure returns (int128 _amount0) {
        assembly ("memory-safe") {
            _amount0 := sar(128, balanceDelta)
        }
    }

    function amount1(BalanceDelta balanceDelta) internal pure returns (int128 _amount1) {
        assembly ("memory-safe") {
            _amount1 := signextend(15, balanceDelta)
        }
    }
}

/// @dev The two casts v4's `SafeCast` lends the delta arithmetic. Same revert, same checks.
library V4SafeCast {
    error SafeCastOverflow();

    function toInt128(int256 x) internal pure returns (int128 y) {
        y = int128(x);
        if (y != x) revert SafeCastOverflow();
    }

    function toInt128(uint256 x) internal pure returns (int128 y) {
        if (x > uint128(type(int128).max)) revert SafeCastOverflow();
        y = int128(uint128(x));
    }
}

// ---- interfaces/IHooks.sol, the one callback this hook answers ----

/// @notice V4 decides whether to invoke specific hooks by inspecting the least significant bits
/// of the address that the hooks contract is deployed to.
/// For example, a hooks contract deployed to address: 0x0000000000000000000000000000000000002400
/// has the lowest bits '10 0100 0000 0000' which would cause the 'before initialize' and 'after add liquidity' hooks to be used.
interface IHooks {
    /// @notice The hook called before a swap
    /// @param sender The initial msg.sender for the swap call
    /// @param key The key for the pool
    /// @param params The parameters for the swap
    /// @param hookData Arbitrary data handed into the PoolManager.swap() call
    /// @return bytes4 The function selector for the hook
    /// @return BeforeSwapDelta The hook's delta in specified and unspecified currencies. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    /// @return uint24 Optionally override the lp fee, only used if three conditions are met: 1. the Pool has a dynamic fee, 2. the value's 2nd highest bit is set (23rd bit, 0x400000), and 3. the value is less than or equal to the maximum fee (1 million)
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24);
}

// ---- libraries/Hooks.sol, the bits and the errors the stub manager reproduces ----

library Hooks {
    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 internal constant AFTER_SWAP_FLAG = 1 << 6;
    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3;

    /// @notice thrown when a hook call fails
    error HookCallFailed();
    /// @notice thrown when a hook returns invalid data
    error InvalidHookResponse();
    /// @notice The hook's delta changed the swap from exactIn to exactOut or vice versa
    error HookDeltaExceedsSwapAmount();

    function hasPermission(IHooks self, uint160 flag) internal pure returns (bool) {
        return uint160(address(self)) & flag != 0;
    }
}
