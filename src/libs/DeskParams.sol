// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The maker's whole commitment. Frozen at ship() because Aqua hashes the strategy.
struct DeskParams {
    address base;             // the asset with a perp on HyperCore (UBTC)
    address quote;            // what it is priced in (USDT0)
    uint32 perpIndex;         // HyperCore perp index of base (BTC = 0)
    uint64 pxNum;             // raw L1 px -> quote units per base unit, numerator
    uint64 pxDen;             // denominator. BTC on UBTC(8)/USDT0(6), szDecimals 5: 1 / 1000
    uint16 quietBps;          // how far outside L1 the desk sits when nothing is happening
    uint16 leanBps;           // how far inside the L1 spread the absorbing side moves under stress
    uint16 stressBps;         // |oracle - mark| / oracle at which the book alone declares stress
    address mapOracle;        // zero means book-only
    uint32 mapMaxAge;         // seconds after which a map is ignored
    uint128 mapMinNotional;   // forced notional within 1% that counts as stress
    uint128 minBase;          // inventory band on the strategy's base balance after the fill
    uint128 maxBase;
}

library DeskParamsLib {
    uint256 internal constant BPS = 10_000;

    function encode(DeskParams memory p) internal pure returns (bytes memory) {
        return abi.encode(p);
    }

    function decode(bytes calldata args) internal pure returns (DeskParams memory) {
        return abi.decode(args, (DeskParams));
    }

    /// @notice pxNum / pxDen such that amountQuote = amountBase * rawPx * pxNum / pxDen.
    function priceScale(uint8 szDecimals, uint8 baseDecimals, uint8 quoteDecimals)
        internal
        pure
        returns (uint64 pxNum, uint64 pxDen)
    {
        revert("todo");
    }
}
