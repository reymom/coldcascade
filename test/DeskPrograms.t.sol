// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { XYCSwap } from "@1inch/swap-vm/src/instructions/XYCSwap.sol";
import { Extruction } from "@1inch/swap-vm/src/instructions/Extruction.sol";
import { Controls } from "@1inch/swap-vm/src/instructions/Controls.sol";
import { Fee, FeeArgsBuilder } from "@1inch/swap-vm/src/instructions/Fee.sol";
import { Program, ProgramBuilder } from "@1inch/swap-vm/test/utils/ProgramBuilder.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { DeskTest } from "./base/DeskTest.sol";
import { DeskParams, DeskParamsLib } from "../src/libs/DeskParams.sol";
import { DeskPrograms } from "../src/libs/DeskPrograms.sol";
import { CoreQuote } from "../src/CoreQuote.sol";
import { DemoToken } from "../src/DemoToken.sol";

/// @notice The encoder is the one place a program can be got wrong, so it is the one place with a
///         byte-for-byte test. F4 lives here: Aqua keys a strategy by `keccak256(strategy)` while
///         the router hashes `keccak256(abi.encode(order))`, and the two agree only because both
///         sides go through `strategyBytes`.
contract DeskProgramsTest is DeskTest {
    using ProgramBuilder for Program;

    bytes32 internal constant SALT = keccak256("desk-1");
    uint256 internal constant START_BASE = 10e8;
    uint256 internal constant START_QUOTE = 800_000e6;

    /// @dev **An opcode is a position in the router's own table**, so the three constants in
    ///      `DeskPrograms` are the one thing in the encoder that could silently become wrong: reorder
    ///      `AquaOpcodes._opcodes()` and a desk ships a program that dispatches into a different
    ///      instruction, with no error anywhere. This derives them from the table itself.
    function test_opcodes_matchTheRoutersOwnTable() public view {
        Program memory table = ProgramBuilder.init(_opcodes());
        assertEq(table.findOpcode(XYCSwap._xycSwapXD), DeskPrograms.OP_XYC_SWAP, "XYCSwap");
        assertEq(table.findOpcode(Controls._salt), DeskPrograms.OP_SALT, "Salt");
        assertEq(table.findOpcode(Extruction._extruction), DeskPrograms.OP_EXTRUCTION, "Extruction");
        assertEq(table.findOpcode(Fee._flatFeeAmountInXD), DeskPrograms.OP_FLAT_FEE_IN, "FlatFeeIn");
    }

    /// @dev The hardened control exists so that "compared to what?" has an answer a judge cannot
    ///      call a strawman, and it is built out of 1inch's own instruction rather than an AMM we
    ///      wrote — a control you write yourself is a foil. Two ways it could be silently wrong,
    ///      both asserted here: the fee has to precede the curve, because it drives the rest of the
    ///      program through `runLoop` and reverts if a leg is already written; and its `feeBps` is
    ///      in 1e9, so a number that reads like basis points charges nothing.
    function test_hardControlProgramBytes() public view {
        Program memory table = ProgramBuilder.init(_opcodes());
        uint32 feeBps = 3_000_000; // 30 bps, at BPS = 1e9

        assertEq(
            DeskPrograms.hardControl(feeBps, SALT),
            bytes.concat(
                table.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(feeBps)),
                table.build(XYCSwap._xycSwapXD),
                table.build(Controls._salt, abi.encodePacked(SALT))
            ),
            "the fee wraps the curve; it does not follow it"
        );
    }

    /// @dev And the bytes around those opcodes are 1inch's own instruction layout, built by their
    ///      `ProgramBuilder` rather than by ours, in the order the quote depends on.
    function test_canonicalProgramBytes() public view {
        DeskParams memory p = btcParams();
        Program memory table = ProgramBuilder.init(_opcodes());
        bytes memory program = DeskPrograms.desk(address(coreQuote), p);

        bytes memory xyc = table.build(XYCSwap._xycSwapXD);
        bytes memory extruction =
            table.build(Extruction._extruction, abi.encodePacked(address(coreQuote), DeskParamsLib.encode(p)));
        bytes memory salt = table.build(Controls._salt, abi.encodePacked(SALT));

        assertEq(program, bytes.concat(xyc, extruction), "the desk program is XYCSwap || Extruction(CoreQuote, params)");
        assertEq(
            DeskPrograms.deskWithSalt(address(coreQuote), p, SALT),
            bytes.concat(program, salt),
            "the salt is appended, never woven in"
        );
        assertEq(
            DeskPrograms.control(SALT), bytes.concat(xyc, salt), "the control is the same curve with the bound removed"
        );
    }

    /// @dev F6, and it has changed shape. The curve fills the leg and CoreQuote bounds what it
    ///      filled. Reversed, `XYCSwap` finds `amountOut` already written by the Extruction and
    ///      reverts `XYCSwapRecomputeDetected` — the deployed SwapVM refuses to recompute a leg
    ///      another instruction has set, so the ordering mistake is now impossible rather than
    ///      silent. The ordered program still has to be bounded to the book, which is the half of
    ///      this that is ours.
    function test_curveComesBeforeQuote() public {
        DeskParams memory p = btcParams();
        Program memory table = ProgramBuilder.init(_opcodes());
        bytes memory ordered = DeskPrograms.deskWithSalt(address(coreQuote), p, SALT);
        bytes memory reversed = bytes.concat(
            table.build(Extruction._extruction, abi.encodePacked(address(coreQuote), DeskParamsLib.encode(p))),
            table.build(XYCSwap._xycSwapXD),
            table.build(Controls._salt, abi.encodePacked(SALT))
        );

        // Inventory priced far above the book, so the constant product is the generous side.
        uint256 richQuote = 8_000_000e6;
        (, uint256 bounded) = quoteRouter(
            shipped(DeskPrograms.order(maker, address(hooks), ordered, p), p, START_BASE, richQuote),
            p,
            ONE_UBTC,
            true,
            true
        );
        ISwapVM.Order memory backwards =
            shipped(DeskPrograms.order(maker, address(hooks), reversed, p), p, START_BASE, richQuote);
        ISwapVM view_ = swapVM.asView();
        (address tokenIn, address tokenOut) = pair(p, true);
        bytes memory td = deskTakerData(address(taker), true, false);

        vm.expectRevert(XYCSwap.XYCSwapRecomputeDetected.selector);
        view_.quote(backwards, tokenIn, tokenOut, ONE_UBTC, td);

        assertEq(bounded, ONE_UBTC * QUIET_BID * (10_000 - QUIET_BPS) / 10_000_000, "bounded to the quiet desk bid");
    }

    /// @dev F4, pinned. Aqua hashes the calldata it was handed; the router hashes the order struct.
    ///      Ship anything but `strategyBytes(order)` and the balances land under a hash no swap can
    ///      reach — the strategy is shipped, funded and unreachable, with no error anywhere.
    function test_strategyHashMatchesAquaAndRouter() public {
        DeskParams memory p = btcParams();
        ISwapVM.Order memory o = deskOrder(p, SALT);

        bytes32 strategyHash = shipFunded(o, p, START_BASE, START_QUOTE);

        assertEq(strategyHash, swapVM.hash(o), "Aqua's key is the router's order hash");
        assertEq(strategyHash, keccak256(DeskPrograms.strategyBytes(o)), "and both are keccak of the shipped bytes");

        (uint256 balanceBase, uint256 balanceQuote) =
            aqua.safeBalances(maker, address(swapVM), strategyHash, p.base, p.quote);
        assertEq(balanceBase, START_BASE, "the base leg landed under the reachable hash");
        assertEq(balanceQuote, START_QUOTE, "and so did the quote leg");
    }

    /// @dev Aqua refuses a hash it has already seen — `dock` marks the balance docked, it does not
    ///      free the key. Reopening a desk with the parameters it already had is the ordinary case,
    ///      so every account ships salted and this is why.
    function test_sameProgramTwice_needsSalt() public {
        DeskParams memory p = btcParams();
        ISwapVM.Order memory first = deskOrder(p, SALT);
        shipFunded(first, p, START_BASE, START_QUOTE);

        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (START_BASE, START_QUOTE);
        bytes memory strategy = DeskPrograms.strategyBytes(first);

        vm.expectRevert(
            abi.encodeWithSelector(IAqua.StrategiesMustBeImmutable.selector, address(swapVM), swapVM.hash(first))
        );
        vm.prank(maker);
        aqua.ship(address(swapVM), strategy, DeskPrograms.tokens(p), amounts);

        // A different salt is a different program, a different order, a different hash.
        ISwapVM.Order memory second = deskOrder(p, keccak256("desk-2"));
        assertTrue(swapVM.hash(second) != swapVM.hash(first), "the salt is what makes the second desk shippable");
        assertEq(shipFunded(second, p, START_BASE, START_QUOTE), swapVM.hash(second), "and it ships");
    }

    /// @dev Docking does not free the key either — the same order cannot come back after a close.
    function test_dockedProgram_cannotBeReshipped() public {
        DeskParams memory p = btcParams();
        ISwapVM.Order memory o = deskOrder(p, SALT);
        bytes32 strategyHash = shipFunded(o, p, START_BASE, START_QUOTE);

        vm.prank(maker);
        aqua.dock(address(swapVM), strategyHash, DeskPrograms.tokens(p));

        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (START_BASE, START_QUOTE);
        bytes memory strategy = DeskPrograms.strategyBytes(o);

        vm.expectRevert(
            abi.encodeWithSelector(IAqua.StrategiesMustBeImmutable.selector, address(swapVM), strategyHash)
        );
        vm.prank(maker);
        aqua.ship(address(swapVM), strategy, DeskPrograms.tokens(p), amounts);
    }

    /// @dev The order names no tokens: in the SwapVM the desk is deployed against, the taker gives
    ///      `tokenIn` and `tokenOut` at the call. That is worth pinning, because an earlier revision
    ///      of the router carried a sorted pair inside the order and this one does not — so the
    ///      question "what stops a taker naming a pair the maker never shipped" has a new answer.
    ///
    ///      It is Aqua, one layer below the program: balances are keyed by strategy *and* token, so
    ///      a token the strategy never shipped has no balance to read and the call reverts before an
    ///      instruction runs. `CoreQuote.WrongPair` is the second gate, for a pair that is in the
    ///      strategy but not the one these parameters price.
    function test_order_namesNoPair_soTheQuoteChecksIt() public {
        DeskParams memory p = btcParams();
        ISwapVM.Order memory o = deskOrder(p, SALT);
        shipFunded(o, p, START_BASE, START_QUOTE);

        DemoToken stranger = new DemoToken("Stranger", "STR", 18);
        ISwapVM view_ = swapVM.asView();
        bytes memory td = deskTakerData(address(taker), true, false);
        bytes32 strategyHash = swapVM.hash(o);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAqua.SafeBalancesForTokenNotInActiveStrategy.selector,
                maker,
                address(swapVM),
                strategyHash,
                address(stranger)
            )
        );
        view_.quote(o, address(stranger), address(usdt0), ONE_UBTC, td);

        // And the desk's own pair, the other way round, is a quote and not an error.
        (, uint256 out) = quoteRouter(o, p, ONE_UBTC, true, true);
        assertGt(out, 0, "the pair the strategy shipped still prices");
    }

    /// @dev The constraint the encoding exists for. SwapVM writes an instruction as
    ///      `[opcode][uint8 length][args]`, so one instruction carries at most 255 bytes and
    ///      Extruction spends 20 of them on the target. `abi.encode(DeskParams)` is 416, which does
    ///      not build at all; packed it is 138, and the whole desk program is under 200 bytes.
    function test_paramsFitOneInstruction() public view {
        DeskParams memory p = btcParams();
        bytes memory packed = DeskParamsLib.encode(p);

        assertEq(packed.length, DeskParamsLib.ENCODED_LENGTH, "the encoding is fixed width");
        assertEq(abi.encode(p).length, 416, "what the word-padded encoding would have cost");
        assertLt(packed.length + 20, 256, "target plus args has to fit the instruction's length byte");
        assertLt(DeskPrograms.deskWithSalt(address(coreQuote), p, SALT).length, 256, "the whole program, for scale");
    }

    /// @dev Round trip through the same calldata path `extruction` reads, field by field, and a
    ///      wrong length rejected rather than read as a desk with a zero inventory band.
    function test_paramsRoundTrip() public {
        DeskParams memory p = btcParams();
        p.mapOracle = address(mapOracle);
        p.minBase = 1e7;
        p.maxBase = 100e8;

        DeskParams memory back = this.decodeParams(DeskParamsLib.encode(p));
        assertEq(keccak256(abi.encode(back)), keccak256(abi.encode(p)), "every field survives the round trip");

        vm.expectRevert(abi.encodeWithSelector(DeskParamsLib.MalformedParams.selector, uint256(137)));
        this.decodeParams(new bytes(137));
    }

    /// @dev `decode` takes calldata, so the test has to hand it some.
    function decodeParams(bytes calldata args) external pure returns (DeskParams memory) {
        return DeskParamsLib.decode(args);
    }

    // ---- helpers ----

    uint256 internal constant ONE_UBTC = 1e8;

    function shipped(ISwapVM.Order memory o, DeskParams memory p, uint256 amountBase, uint256 amountQuote)
        internal
        returns (ISwapVM.Order memory)
    {
        shipFunded(o, p, amountBase, amountQuote);
        return o;
    }

    function _slice(bytes memory data, uint256 start, uint256 length) private pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i = 0; i < length; ++i) {
            out[i] = data[start + i];
        }
    }
}
