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

    /// @notice Fixed width of the packed encoding, in bytes.
    /// @dev SwapVM writes an instruction as `[opcode][uint8 length][args]`, so **one instruction
    ///      carries at most 255 bytes of args** (`InstructionBuilder.patchLength`). Extruction
    ///      spends 20 of them on the target address, which leaves 235 for the maker's parameters.
    ///      `abi.encode` of this struct is 416 — thirteen fields padded to a word each — and a desk
    ///      program encoded that way does not build. Packed, the same thirteen fields are 138.
    ///
    ///      So the encoding is fixed-width packed, and it is exact: `decode` rejects any other
    ///      length rather than reading a short buffer as zeros. The struct is what a maker signs
    ///      for and what the strategy hash freezes (F3); a field added here changes both, which is
    ///      the intended cost of touching it.
    uint256 internal constant ENCODED_LENGTH = 138;

    error PriceScaleOutOfRange(int256 exponent);
    error MalformedParams(uint256 length);

    /// @dev Field order is the struct's. `abi.encodePacked` gives each field its own width, so the
    ///      layout is: base 20 | quote 20 | perpIndex 4 | pxNum 8 | pxDen 8 | quietBps 2 |
    ///      leanBps 2 | stressBps 2 | mapOracle 20 | mapMaxAge 4 | mapMinNotional 16 |
    ///      minBase 16 | maxBase 16.
    function encode(DeskParams memory p) internal pure returns (bytes memory) {
        return abi.encodePacked(
            p.base,
            p.quote,
            p.perpIndex,
            p.pxNum,
            p.pxDen,
            p.quietBps,
            p.leanBps,
            p.stressBps,
            p.mapOracle,
            p.mapMaxAge,
            p.mapMinNotional,
            p.minBase,
            p.maxBase
        );
    }

    /// @dev The mirror, read straight out of calldata. A wrong length is a malformed program, not
    ///      a quote of zero: the desk would otherwise fill against `maxBase == 0` and revert
    ///      somewhere less obvious.
    function decode(bytes calldata args) internal pure returns (DeskParams memory p) {
        if (args.length != ENCODED_LENGTH) revert MalformedParams(args.length);
        p.base = address(bytes20(args[0:20]));
        p.quote = address(bytes20(args[20:40]));
        p.perpIndex = uint32(bytes4(args[40:44]));
        p.pxNum = uint64(bytes8(args[44:52]));
        p.pxDen = uint64(bytes8(args[52:60]));
        p.quietBps = uint16(bytes2(args[60:62]));
        p.leanBps = uint16(bytes2(args[62:64]));
        p.stressBps = uint16(bytes2(args[64:66]));
        p.mapOracle = address(bytes20(args[66:86]));
        p.mapMaxAge = uint32(bytes4(args[86:90]));
        p.mapMinNotional = uint128(bytes16(args[90:106]));
        p.minBase = uint128(bytes16(args[106:122]));
        p.maxBase = uint128(bytes16(args[122:138]));
    }

    /// @notice pxNum / pxDen such that amountQuote = amountBase * rawPx * pxNum / pxDen.
    /// @dev A raw L1 price is USD * 10^(6 - szDecimals), so the whole scale is a power of ten:
    ///      10^(quoteDecimals + szDecimals - 6 - baseDecimals). BTC (szDecimals 5) on UBTC(8)
    ///      against USDT0(6) gives 10^-3, which is the 1 / 1000 the desk ships with.
    function priceScale(uint8 szDecimals, uint8 baseDecimals, uint8 quoteDecimals)
        internal
        pure
        returns (uint64 pxNum, uint64 pxDen)
    {
        int256 e = int256(uint256(quoteDecimals)) + int256(uint256(szDecimals))
            - 6 - int256(uint256(baseDecimals));
        if (e > 18 || e < -18) revert PriceScaleOutOfRange(e);
        if (e >= 0) return (uint64(10 ** uint256(e)), 1);
        return (1, uint64(10 ** uint256(-e)));
    }
}
