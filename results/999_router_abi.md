# The SwapVM on 999 is not the SwapVM on `main`

**Chain 999, verified 2026-09-05.** The router at `0x111111338c5091E8440b67B168bAe16a668AC0De`
answers `AQUA()` with `0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a` and `eip712Domain()` with
`("1inch SwapVM v1.0", "1.0", 999)`. It is 1inch's own deployment and it is the one the prize
requires.

It does not have the ABI this repository was built against, and the way that surfaced is worth
recording: every test passed, the strategy shipped, Aqua accepted it, and the first `quote` against
the real router reverted with no data at 339 gas.

## What is different

`quote` and `swap` on the deployed contract are:

```
quote((address,uint256,bytes), address tokenIn, address tokenOut, uint256 amount, bytes takerTraitsAndData)  0x44aa5f14
swap ((address,uint256,bytes), address tokenIn, address tokenOut, uint256 amount, bytes takerTraitsAndData)  0xf4d2d412
```

Against `0xb7ebf0c5` and `0xa69f95bd` for the three-argument versions the repository had pinned.
`hash((address,uint256,bytes))` matches and `ORDER_TYPEHASH` is byte-identical
(`0x4ff6e0f2…3d40` = `keccak256("Order(address maker,uint256 traits,bytes data)")`), so the Order
struct never moved — the taker's side of the call did.

The tell that fixes the version: the deployed contract has **no `WETH()` getter**. `v1.0.x` of
SwapVM holds only `AQUA` as an immutable; the later revision on `main` added `IWETH public
immutable WETH`. Everything else follows from that:

| | deployed (`v1.0.x`) | pinned `main` commit `9502fd44` |
|---|---|---|
| `quote` / `swap` | taker names `tokenIn`, `tokenOut` | derived from an `isAToB` taker flag |
| `MakerTraitsLib.Args` | no tokens in the order | `tokenA` / `tokenB`, required sorted |
| `TakerTraitsLib.Args` | — | adds `isAToB`, `allowPartialFill` |
| `IMakerHooks` | 9 parameters | 10, with `feeIn` / `feeOut` |
| `SwapRegisters` | 5 fields | 5, `amountNetPulled` present in both |
| instruction builders | `ProgramBuilder` + `ControlsArgsBuilder` | `XYCSwap.build()`, `Extruction.build()`, `Salt.build()` |
| `XYCSwap` recompute | reverts `XYCSwapRecomputeDetected` | overwrites silently |

The pin is now `github:1inch/swap-vm#v1.0.2` and `github:1inch/aqua#v1.0.0`.

## The opcode is a position, not a number

The largest hazard in the change. An instruction's opcode is its **index in
`AquaOpcodes._opcodes()`**, an array of function pointers, so a program is only valid against the
table the router was compiled with. The three this desk needs are `XYCSwap` **17**, `Salt` **20**
and `Extruction` **32**; the first guess from reading the array was 18 / 21 / 33, which produced a
program that dispatched into `XYCConcentrate` and reverted `ConcentrateMissingSqrtPriceMin`.

`test_opcodes_matchTheRoutersOwnTable` derives all three from `_opcodes()` with 1inch's own
`ProgramBuilder.findOpcode` rather than trusting the constants, so a reordering upstream fails the
suite instead of shipping a strategy that runs the wrong instruction. `AquaOpcodesDebug` only
overwrites indices 0–4, which are unused in the base table, so the numbers the tests see are the
numbers the deployed router uses.

## The death metric, on the deployed router

Against a fork of 999 at block 45 114 120 with the real Aqua and the real SwapVM, the precompiles
mocked because a fork cannot serve them. Two swaps of 1 000 dUSDT0 into the demo desk, with the
book moved between them and nothing else touched:

| | L1 bid / ask | desk bid / ask | `amountOut` |
|---|---|---|---|
| first | 799 500 / 799 510 | 797 901 / 801 110 | **1 242 236** |
| after the book moves | 810 000 / 810 010 | 808 380 / 811 631 | **1 226 899** |

Both settled through `swap()` on `0x1111113…C0De` and emitted `Fill` with the four L1 words in it.
The same 1 000 units of quote buy less base when base is dearer on Hyperliquid, which is the whole
claim: **a swap whose `amountOut` moves when the book moves, on official Aqua.**

Reproduce with `./script/localnet.sh`, then move the book and swap again — the last two lines it
prints are those two commands.
