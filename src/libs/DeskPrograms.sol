// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";

import { DeskParams, DeskParamsLib } from "./DeskParams.sol";

/// @notice The one place that concatenates. Order is load-bearing: the curve fills the leg,
///         then CoreQuote bounds it. The control strategy is the same order without the bound.
/// @dev The order itself is built by 1inch's own `MakerTraitsLib.build`; only the program bytes are
///      assembled here, and a SwapVM instruction is `[opcode][uint8 length][args]` — the same three
///      fields `ProgramBuilder` writes in their test utilities.
///
///      **The opcode is an index into the router's own instruction table**, not a stable number.
///      `AquaOpcodes._opcodes()` returns an array of function pointers and an instruction's opcode
///      is its position in it, so a router deployed from a different revision could answer to a
///      different table. The three this program needs are named as constants below and
///      `test_opcodes_matchTheRoutersOwnTable` derives them from the deployed router's table
///      instead of trusting the constants — if 1inch reorders the array, that test fails rather
///      than the desk shipping a strategy that dispatches into the wrong instruction.
library DeskPrograms {
    using DeskParamsLib for DeskParams;

    /// @dev Positions in `AquaOpcodes._opcodes()`, checked against the table in the suite.
    uint8 internal constant OP_SALT = 20;
    uint8 internal constant OP_XYC_SWAP = 17;
    uint8 internal constant OP_EXTRUCTION = 32;
    uint8 internal constant OP_FLAT_FEE_IN = 21;

    /// @dev `[opcode][uint8 length][args]`. The length byte is why one instruction carries at most
    ///      255 bytes of args, which is the constraint `DeskParamsLib`'s packed encoding exists for.
    function instruction(uint8 opcode, bytes memory args) internal pure returns (bytes memory) {
        return abi.encodePacked(opcode, uint8(args.length), args);
    }

    /// @return XYCSwap || Extruction(coreQuote, packed(p))
    function desk(address coreQuote, DeskParams memory p) internal pure returns (bytes memory) {
        return bytes.concat(
            instruction(OP_XYC_SWAP, ""),
            instruction(OP_EXTRUCTION, abi.encodePacked(coreQuote, p.encode()))
        );
    }

    /// @return XYCSwap || Extruction(coreQuote, packed(p)) || Salt(salt)
    /// @dev Aqua keys a strategy by `keccak256(strategy)` and refuses to ship the same hash twice,
    ///      even after a dock. A desk that reopens with the parameters it already had is the normal
    ///      case, so every account ships with a salt rather than discovering this at the second open.
    function deskWithSalt(address coreQuote, DeskParams memory p, bytes32 salt)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(desk(coreQuote, p), instruction(OP_SALT, abi.encodePacked(salt)));
    }

    /// @return XYCSwap || Salt(salt) — the other line on the screen
    function control(bytes32 salt) internal pure returns (bytes memory) {
        return bytes.concat(instruction(OP_XYC_SWAP, ""), instruction(OP_SALT, abi.encodePacked(salt)));
    }

    /// @return FlatFeeIn(feeBps) || XYCSwap || Salt(salt) — the third line, and the honest one.
    ///
    /// @notice The plain control is the right *ablation* — it is `desk()` with one instruction
    ///         removed, so a difference between the two is that instruction and nothing else. It is
    ///         not a fair *competitor*: nobody ships a zero-fee constant product on a BTC pair. This
    ///         is the same curve charging for the privilege, which is what people actually deploy.
    ///
    /// @dev Two things about the ordering and the unit, both of which are the router's and not
    ///      ours, and both of which bite:
    ///
    ///      **The fee comes before the curve.** `Fee._flatFeeAmountInXD` reverts
    ///      `FeeShouldBeAppliedBeforeSwapAmountsComputation` if either leg is already written, and
    ///      it drives the rest of the program itself through `ctx.runLoop()`. So it wraps the
    ///      curve rather than following it; `XYCSwap || FlatFee` does not build a fee'd AMM, it
    ///      builds a revert. Upstream's own `Fee.t.sol` and `XYCSwap.t.sol` order it this way.
    ///
    ///      **`feeBps` is in 1e9, not 1e4.** The deployed revision's `Fee` uses `BPS = 1e9`, so a
    ///      basis point is 100 000 and 30 bps — roughly what a real BTC/USDT pool charges — is
    ///      3 000 000. A number that looks like basis points here is off by five orders of
    ///      magnitude and the control silently becomes free again.
    function hardControl(uint32 feeBps, bytes32 salt) internal pure returns (bytes memory) {
        return bytes.concat(
            instruction(OP_FLAT_FEE_IN, abi.encodePacked(feeBps)),
            instruction(OP_XYC_SWAP, ""),
            instruction(OP_SALT, abi.encodePacked(salt))
        );
    }

    /// @return Extruction(pegQuote, key) || XYCSwap || Salt(salt) — the oracle-pegged comparator.
    ///
    /// @notice The third line, and the one a reader will not call a straw man. `PegQuote` puts the
    ///         curve's marginal price on Hyperliquid's oracle as of its last `refresh`, so what
    ///         follows is the *same* `XYCSwap` the control runs, on the same reserves, centred
    ///         somewhere else.
    ///
    /// @dev The extruction comes **first**, unlike the desk's, and for the opposite reason. The
    ///      desk's runs last because it bounds a leg the curve has already filled; this one runs
    ///      first because it sets the balances the curve is about to read. Swap the order and the
    ///      re-centring lands after the arithmetic it was supposed to change, which is not a
    ///      revert — it is a maker that silently quotes off its own reserves and a line on the
    ///      screen that is the plain control drawn twice.
    ///
    ///      The args are the key and nothing else: everything about this maker lives in the
    ///      `PegQuote` entry that key names, because the peg has to be able to move without the
    ///      program changing. A program that carried the price would need re-shipping to refresh,
    ///      and Aqua keys a strategy by its hash, so every refresh would be a different maker.
    function oraclePegged(address pegQuote, bytes32 key, bytes32 salt)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            instruction(OP_EXTRUCTION, abi.encodePacked(pegQuote, key)),
            instruction(OP_XYC_SWAP, ""),
            instruction(OP_SALT, abi.encodePacked(salt))
        );
    }

    /// @notice An Aqua order (useAquaInsteadOfSignature) with the desk hook on post-transfer-out.
    /// @param hooks The single `DeskHooks` instance, or zero for a strategy that emits no Fill —
    ///        the control ships that way so the two lines differ by the quote and nothing else.
    /// @dev `postTransferOutData` is the same packed `DeskParams` the program carries, so the hook
    ///      reads the perp index and the map oracle out of calldata instead of storage.
    ///
    ///      The order names no tokens. The taker names them at `quote`/`swap` and the desk checks
    ///      the pair inside `CoreQuote`, which reverts on anything but its own two.
    function order(address maker, address hooks, bytes memory program, DeskParams memory p)
        internal
        pure
        returns (ISwapVM.Order memory)
    {
        bool hasHook = hooks != address(0) && hooks != maker;

        return MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: maker,
                receiver: address(0), // the maker itself: an account's fills come back to the account
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: true,
                allowZeroAmountIn: false,
                hasPreTransferInHook: false,
                hasPostTransferInHook: false,
                hasPreTransferOutHook: false,
                hasPostTransferOutHook: hasHook,
                preTransferInTarget: address(0),
                preTransferInData: "",
                postTransferInTarget: address(0),
                postTransferInData: "",
                preTransferOutTarget: address(0),
                preTransferOutData: "",
                postTransferOutTarget: hasHook ? hooks : address(0),
                postTransferOutData: hasHook ? p.encode() : bytes(""),
                program: program
            })
        );
    }

    /// @notice What ship() must receive, byte for byte: Aqua hashes the raw calldata and SwapVM
    ///         hashes keccak256(abi.encode(order)). Anything else ships an unreachable strategy.
    function strategyBytes(ISwapVM.Order memory o) internal pure returns (bytes memory) {
        return abi.encode(o);
    }

    /// @notice The two tokens in the order Aqua's `ship` and `dock` want them.
    /// @dev `dock` requires the token count it is given to equal the count `ship` recorded, so the
    ///      two calls have to agree on the array. One function, both call sites.
    function tokens(DeskParams memory p) internal pure returns (address[] memory list) {
        list = new address[](2);
        (list[0], list[1]) = (p.base, p.quote);
    }
}
