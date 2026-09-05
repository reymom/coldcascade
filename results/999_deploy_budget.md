# What it costs to put this on 999, and what the block allows

**Chain 999, measured 2026-09-05** on a local fork of block 45 111 979 with the real Aqua and the
real SwapVM router. Reproduce with `./script/localnet.sh`.

## HyperEVM blocks come in two sizes, and the small one is the default

`gasLimit` over 120 consecutive blocks around 45 111 106:

| gas limit | blocks |
|---|---|
| 3 000 000 | 118 |
| 30 000 000 | 2 |

A transaction lands in a small block unless its sender has opted into big blocks, which is an L1
action and not an EVM one. **How a sender opts in is `[UNVERIFIED]` — probe 2026-09-07**, when the
deployer has a HyperCore account. Everything below is sized so that the answer does not matter.

## Deployment gas, per contract

Code deposit is 200 gas a byte, so on this chain a contract's size is a deployment constraint and
not only a taker cost.

| contract | runtime bytes | deploy gas | fits a small block |
|---|---|---|---|
| `MarkoutLedger` | 552 | 153 461 | yes |
| `DemoMapOracle` | 973 | 257 297 | yes |
| `MapOracle` | 1 086 | 259 867 | yes |
| `CorePrecompiles` | 1 353 | 337 951 | yes |
| `DeskFactory` | 1 316 | ~270 000 | yes |
| `BookCache` | 2 145 | 507 704 | yes |
| `DemoToken` | 1 731 | 692 454 | yes |
| `DeskHooks` | 2 621 | 784 094 | yes |
| `CoreQuote` | 4 851 | 1 354 271 | yes |
| `FloorLens` | 6 639 | 1 870 307 | yes |
| **`DeskAccount`** | **12 361** | **2 863 583** | **yes, with 4.5% to spare** |

Two things came out of that last row.

**The optimizer had to come down.** At `optimizer_runs = 1_000_000` — the setting a maker program
would otherwise want — `DeskAccount` compiled to 18 552 bytes, which is 3 710 400 gas of code
deposit on its own and cannot be deployed in a small block at any price. At 200 runs it is 12 890.
What that costs: a swap went from 93 324 gas to 97 966 against a contract maker, and cover from
41 575 to 42 138. Roughly 5% more gas on the taker's side — half of it this setting and half the
move to the SwapVM revision actually deployed on 999 — at 0.1 gwei, to remove a dependency on an
L1 action from the deploy. Legacy codegen (`via_ir = false`) does not compile this contract at
all, and 1 run instead of 200 saves 161 bytes, so 200 is where the setting sits.

**The factory cannot build the account.** `DeskFactory` used to deploy the `DeskAccount`
implementation inside its own constructor, which is one transaction worth 3.1M gas and therefore no
transaction at all. The implementation is deployed first and handed in. That removed the circular
dependency that made `onlyFactory` possible on `initialize`, so the guard is now the owner slot: the
implementation's constructor takes it, and a clone's blank storage leaves it open for exactly one
call.

Note the padding, too. `forge script` multiplies its gas estimate by 1.3 by default, which turns
2 863 583 into 3 722 658 and a transaction that is refused before it is simulated. The deploy runs
with `--gas-estimate-multiplier 102`.
