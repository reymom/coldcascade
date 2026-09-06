// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AquaSwapVMTest } from "@1inch/swap-vm/test/base/AquaSwapVMTest.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CoreQuote } from "../../src/CoreQuote.sol";
import { CorePrecompiles } from "../../src/CorePrecompiles.sol";
import { DeskHooks } from "../../src/DeskHooks.sol";
import { MapOracle } from "../../src/MapOracle.sol";
import { DemoToken } from "../../src/DemoToken.sol";
import { DemoMapOracle } from "../../src/DemoMapOracle.sol";
import { BookCache } from "../../src/BookCache.sol";
import { MarkoutLedger } from "../../src/MarkoutLedger.sol";
import { FloorLens } from "../../src/FloorLens.sol";
import { DeskAccount } from "../../src/DeskAccount.sol";
import { DeskFactory } from "../../src/DeskFactory.sol";
import { DeskParams, DeskParamsLib } from "../../src/libs/DeskParams.sol";
import { DeskPrograms } from "../../src/libs/DeskPrograms.sol";
import { HyperCore } from "../../src/libs/HyperCore.sol";
import { MockCoreReader } from "../mocks/MockCoreReader.sol";
import { HyperCoreMock } from "../mocks/HyperCoreMock.sol";
import { CoreWriterMock } from "../mocks/CoreWriterMock.sol";

/// @notice Every desk test extends 1inch's own Aqua harness: their Aqua, their router, their
///         MockTaker. What is added is the pair with real decimals, the reader, the hook and the
///         canonical orders.
/// @dev The reader under test is `CorePrecompiles`, reading `HyperCoreMock` etched at 0x0806,
///      0x0807, 0x0809 and 0x080e — the same path the 998 probe measured, mock only at the node
///      boundary. `MockCoreReader` stays available for tests that do not care where a book came
///      from; `setBook` writes both so they never disagree.
abstract contract DeskTest is AquaSwapVMTest {
    uint32 internal constant BTC = 0;

    /// @dev Hyperliquid's system contract, verified to hold code on 999.
    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    /// @dev Quiet book on 999 at block 45 021 360, 2026-09-04. Raw units, szDecimals 5.
    uint64 internal constant QUIET_BID = 795_510;
    uint64 internal constant QUIET_ASK = 795_520;
    uint64 internal constant QUIET_MARK = 795_450;
    uint64 internal constant QUIET_ORACLE = 795_790;

    /// @dev szDecimals of BTC on 999, from perpAssetInfo(0). UBTC has 8 decimals, USDT0 has 6.
    uint8 internal constant BTC_SZ_DECIMALS = 5;
    uint8 internal constant UBTC_DECIMALS = 8;
    uint8 internal constant USDT0_DECIMALS = 6;

    /// @dev Provisional band. ARCHITECTURE §2.3 sets the real one off the Oct-10 run; until that
    ///      run exists these are round numbers chosen to sit either side of the 4 bps the quiet
    ///      999 book showed, and nothing outside the test suite quotes them.
    /// @dev What the owner authorises a cover to pay through the book. 30 bps is wide against a
    ///      4 bps quiet spread, which is the point: the bound exists to stop a cover crossing a
    ///      dislocated book, not to shave the touch.
    uint16 internal constant HEDGE_SLIP_BPS = 30;

    uint16 internal constant QUIET_BPS = 20;
    uint16 internal constant LEAN_BPS = 15;
    uint16 internal constant STRESS_BPS = 25;
    uint32 internal constant MAP_MAX_AGE = 300;
    uint128 internal constant MAP_MIN_NOTIONAL = 5_000_000;

    DemoToken internal ubtc;
    DemoToken internal usdt0;
    MockCoreReader internal reader;
    CorePrecompiles internal precompiles;
    CoreQuote internal coreQuote;
    DeskHooks internal hooks;
    MapOracle internal mapOracle;
    DemoMapOracle internal demoMap;
    BookCache internal bookCache;
    MarkoutLedger internal markoutLedger;
    FloorLens internal lens;
    DeskFactory internal factory;

    function setUp() public virtual override {
        super.setUp();

        etchHyperCore();

        ubtc = new DemoToken("Unit Bitcoin", "UBTC", UBTC_DECIMALS);
        usdt0 = new DemoToken("Tether USD0", "USDT0", USDT0_DECIMALS);

        precompiles = new CorePrecompiles();
        reader = new MockCoreReader();
        coreQuote = new CoreQuote(precompiles);
        hooks = new DeskHooks(address(swapVM), precompiles);
        mapOracle = new MapOracle(address(this));
        demoMap = new DemoMapOracle();
        bookCache = new BookCache();
        markoutLedger = new MarkoutLedger(address(this));
        lens = new FloorLens();
        factory = new DeskFactory(new DeskAccount(aqua, address(swapVM), address(coreQuote), address(hooks)));

        setBook(QUIET_BID, QUIET_ASK, QUIET_MARK, QUIET_ORACLE);
    }

    /// @notice Default parameters for BTC on UBTC(8)/USDT0(6), book-only. Tests override fields.
    function btcParams() internal view returns (DeskParams memory) {
        (uint64 pxNum, uint64 pxDen) =
            DeskParamsLib.priceScale(BTC_SZ_DECIMALS, UBTC_DECIMALS, USDT0_DECIMALS);
        return DeskParams({
            base: address(ubtc),
            quote: address(usdt0),
            perpIndex: BTC,
            pxNum: pxNum,
            pxDen: pxDen,
            quietBps: QUIET_BPS,
            leanBps: LEAN_BPS,
            stressBps: STRESS_BPS,
            mapOracle: address(0),
            mapMaxAge: MAP_MAX_AGE,
            mapMinNotional: MAP_MIN_NOTIONAL,
            minBase: 0,
            maxBase: type(uint128).max
        });
    }

    /// @notice The canonical desk order from `maker`: the curve, then the book bound, then a salt.
    function deskOrder(DeskParams memory p, bytes32 salt) internal view returns (ISwapVM.Order memory) {
        return DeskPrograms.order(maker, address(hooks), DeskPrograms.deskWithSalt(address(coreQuote), p, salt), p);
    }

    /// @notice The other line on the screen: the same pair and inventory, plain XYCSwap, no hook.
    function controlOrder(DeskParams memory p, bytes32 salt) internal view returns (ISwapVM.Order memory) {
        return DeskPrograms.order(maker, address(0), DeskPrograms.control(salt), p);
    }

    /// @notice The third line: the same curve charging a maker fee, which is what people deploy.
    /// @dev `feeBps` is in 1e9 — see `DeskPrograms.hardControl`, and do not read it as basis points.
    function hardControlOrder(DeskParams memory p, uint32 feeBps, bytes32 salt)
        internal
        view
        returns (ISwapVM.Order memory)
    {
        return DeskPrograms.order(maker, address(0), DeskPrograms.hardControl(feeBps, salt), p);
    }

    // ---- the ship harness ----
    //
    // 1inch's own `shipStrategy` is typed to their TokenMock; the desk trades a pair with real
    // decimals, so these are the same four calls over IERC20. Nothing else differs: same Aqua,
    // same router, same MockTaker.

    /// @notice Approve Aqua from `maker` and ship the order with the two starting balances.
    /// @return strategyHash What Aqua keyed the strategy by, which must be the router's order hash.
    function ship(ISwapVM.Order memory o, DeskParams memory p, uint256 amountBase, uint256 amountQuote)
        internal
        returns (bytes32 strategyHash)
    {
        vm.startPrank(maker);
        IERC20(p.base).approve(address(aqua), type(uint256).max);
        IERC20(p.quote).approve(address(aqua), type(uint256).max);

        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (amountBase, amountQuote);
        strategyHash = aqua.ship(address(swapVM), DeskPrograms.strategyBytes(o), DeskPrograms.tokens(p), amounts);
        vm.stopPrank();
    }

    /// @notice Mint both legs to the maker and ship. The taker side is minted per swap.
    function shipFunded(ISwapVM.Order memory o, DeskParams memory p, uint256 amountBase, uint256 amountQuote)
        internal
        returns (bytes32)
    {
        ubtc.mint(maker, amountBase);
        usdt0.mint(maker, amountQuote);
        return ship(o, p, amountBase, amountQuote);
    }

    /// @notice The pair as the router wants it: the desk's bid side is the taker selling base.
    /// @dev The order names no tokens — the taker does, at the call — so this is the only place the
    ///      direction turns into two addresses, and `CoreQuote` rejects any pair but the desk's own.
    function pair(DeskParams memory p, bool bidSide) internal pure returns (address tokenIn, address tokenOut) {
        return bidSide ? (p.base, p.quote) : (p.quote, p.base);
    }

    /// @notice The taker traits, in the two shapes that matter.
    /// @param aquaPush true is what a page sends — the taker approves the router, which pulls and
    ///        pushes into Aqua on the maker's behalf. false is the harness's `MockTaker`, which
    ///        pushes for itself from the pre-transfer-in callback.
    function deskTakerData(address who, bool exactIn, bool aquaPush) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: who,
                isExactIn: exactIn,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: aquaPush,
                threshold: "",
                to: address(0),
                deadline: 0,
                hasPreTransferInCallback: !aquaPush,
                hasPreTransferOutCallback: false,
                preTransferInHookData: "",
                postTransferInHookData: "",
                preTransferOutHookData: "",
                postTransferOutHookData: "",
                preTransferInCallbackData: "",
                preTransferOutCallbackData: "",
                instructionsArgs: "",
                signature: ""
            })
        );
    }

    /// @notice Quote through the official router, exactly as a page would.
    function quoteRouter(ISwapVM.Order memory o, DeskParams memory p, uint256 amount, bool exactIn, bool bidSide)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        (address tokenIn, address tokenOut) = pair(p, bidSide);
        (amountIn, amountOut,) =
            swapVM.asView().quote(o, tokenIn, tokenOut, amount, deskTakerData(address(taker), exactIn, false));
    }

    /// @notice Mint the taker whatever the quote says it will owe. Separate from the swap so a test
    ///         can put `vm.expectEmit` immediately before the call that settles.
    function fundTaker(ISwapVM.Order memory o, DeskParams memory p, uint256 amount, bool exactIn, bool bidSide)
        internal
        returns (uint256 needed)
    {
        (needed,) = quoteRouter(o, p, amount, exactIn, bidSide);
        (bidSide ? ubtc : usdt0).mint(address(taker), needed);
    }

    /// @notice The settling call and nothing else. MockTaker pushes tokenIn into Aqua on the
    ///         pre-transfer-in callback, so the maker ends up holding it.
    function swapOnly(ISwapVM.Order memory o, DeskParams memory p, uint256 amount, bool exactIn, bool bidSide)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        (address tokenIn, address tokenOut) = pair(p, bidSide);
        return taker.swap(o, tokenIn, tokenOut, amount, deskTakerData(address(taker), exactIn, false));
    }

    /// @notice Fund and swap through the official router.
    function swapRouter(ISwapVM.Order memory o, DeskParams memory p, uint256 amount, bool exactIn, bool bidSide)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        fundTaker(o, p, amount, exactIn, bidSide);
        return swapOnly(o, p, amount, exactIn, bidSide);
    }

    /// @notice Mint both legs to `who`, approve the factory and open a desk owned by them.
    function openDesk(address who, string memory deskLabel, DeskParams memory p, uint256 amountBase, uint256 amountQuote)
        internal
        returns (DeskAccount desk)
    {
        ubtc.mint(who, amountBase);
        usdt0.mint(who, amountQuote);

        vm.startPrank(who);
        ubtc.approve(address(factory), amountBase);
        usdt0.approve(address(factory), amountQuote);
        (address account,) = factory.open(deskLabel, p, amountBase, amountQuote);
        vm.stopPrank();

        return DeskAccount(account);
    }

    /// @notice Sets the book on the mock reader and, if etched, on the precompile mocks.
    function setBook(uint64 bid, uint64 ask, uint64 mark, uint64 oracle) internal {
        setBookAt(BTC, bid, ask, mark, oracle);
    }

    function setBookAt(uint32 perpIndex, uint64 bid, uint64 ask, uint64 mark, uint64 oracle) internal {
        reader.set(perpIndex, bid, ask, mark, oracle);
        if (HyperCore.BBO.code.length != 0) {
            HyperCoreMock(payable(HyperCore.BBO)).setBbo(perpIndex, bid, ask);
            HyperCoreMock(payable(HyperCore.MARK_PX)).setPx(perpIndex, mark);
            HyperCoreMock(payable(HyperCore.ORACLE_PX)).setPx(perpIndex, oracle);
        }
    }

    /// @notice Plants HyperCoreMock at the five read precompiles and CoreWriterMock at 0x3333.
    /// @dev One bytecode at five addresses. Storage is per-address and vm.etch copies neither, so
    ///      every instance starts blank and each is set through its own setter — which is why
    ///      `0x080a` is given BTC's real record here and not left as a zero `szDecimals`.
    ///
    ///      The writer is etched too, because `cover` now sends. Nothing in the suite forks a real
    ///      node, and on a fork none of these addresses would work anyway: the read precompiles
    ///      carry no bytecode and are served by the node itself.
    function etchHyperCore() internal {
        bytes memory code = address(new HyperCoreMock()).code;
        vm.etch(HyperCore.MARK_PX, code);
        vm.etch(HyperCore.ORACLE_PX, code);
        vm.etch(HyperCore.L1_BLOCK_NUMBER, code);
        vm.etch(HyperCore.PERP_ASSET_INFO, code);
        vm.etch(HyperCore.POSITION, code);
        vm.etch(HyperCore.BBO, code);
        HyperCoreMock(payable(HyperCore.PERP_ASSET_INFO)).setAssetInfo(BTC, "BTC", 56, BTC_SZ_DECIMALS, 40, false);

        vm.etch(CORE_WRITER, address(new CoreWriterMock()).code);
    }

    /// @notice Put a perp position on a desk, in lots — what a fill on HyperCore leaves behind.
    /// @dev The desk reads its hedge rather than remembering it, so this is how a test says "the
    ///      order landed". Not calling it is how a test says the exchange dropped the order.
    function setPosition(address desk, int64 lots) internal {
        HyperCoreMock(payable(HyperCore.POSITION)).setPosition(desk, BTC, lots);
    }

    /// @notice The etched writer, for building the payload a test expects to see emitted.
    function writer() internal pure returns (CoreWriterMock) {
        return CoreWriterMock(CORE_WRITER);
    }
}
