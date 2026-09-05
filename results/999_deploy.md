# Deployed on HyperEVM mainnet — chain 999, 6 September 2026

Twelve contracts in blocks 45 135 478 → 45 135 503, three desks shipped in 45 135 575 → 45 135 599.
**Total cost 0.001233 HYPE**, about five cents. Address book: `deployments/999.json`.

## What is live

| | address | tx |
|---|---|---|
| `CoreQuote` | `0xE4DE197A81dEa935F72557DC5Bd4F6f1e194Df2B` | `0x5932425b…` |
| `CorePrecompiles` | `0x81BCe7eec25700c79c5CFEad37D2F5D89C2ea669` | `0x2f38cb2c…` |
| `DeskHooks` | `0x84C1D720787F7D197dfc2890862E69c42aB0A363` | `0xfe4921cd…` |
| `DeskAccount` impl | `0x9Eb31e6E2BF2609050Ab80Fd174289b613cB05CA` | `0xed189c35…` |
| `DeskFactory` | `0xd72e2293a37DAd1596c68a35261Eef6B8B7c093d` | `0xea9f7f6c…` |
| `FloorLens` | `0x742d06A6F5e0a0465D495aBae5d0b077849606C7` | `0x7aee04f6…` |
| `MarkoutLedger` | `0xC938e0deD6A7a65B8f92Ca56E8688801eF0Ad0e9` | `0x8c5b0ad1…` |
| `MapOracle` | `0xc192968786D9Fe6f9Da65aebc546970c4cF3C1D7` | `0x58dcc8a9…` |
| `BookCache` | `0x24496697E43dE61af09561fb414cb909C1635533` | `0x6026be86…` |

**The desks.** Canonical `0xCbDe7c24B5963d01eC64b08BB4e2e8BA1707A197` holds 12 500 UBTC-raw and
10 USD₮0 of real inventory. Demo `0xC76137e49BF4D323190a4Ee694b47D5a2Ac515B2` runs on mintable
tokens so a visitor can take it for nothing. The control is the deployer EOA shipping plain
`XYCSwap` on the same pair, and it exists to be the thing the desk is measured against.

## The reader answers the live book

`CorePrecompiles.read(0)` on the deployed contract, against the node:

```
bid 798 210   ask 798 220   mark 798 220   oracle 798 556
```

and `0x080e` called directly returns `0xc2e02` / `0xc2e0c` — 798 210 and 798 220. **The same two
words.** A contract on 999 is reading Hyperliquid's BTC book, and that is the whole thesis in one
`eth_call`.

## Three failures, and all three were the node

None of them was a bug in the contracts, and none could be caught by a local test. They are the
reason the deploy script is what it is.

**1 · `nonce too high`, after 8 of 12 contracts.** HyperEVM rejects a nonce ahead of the account's
current state instead of queueing it; `forge` fires the batch without waiting for receipts. Cost:
eight orphaned contracts and 0.00046 HYPE. Fixed with `--slow`, which sends one transaction and
waits for its receipt before the next — in the script, so it cannot recur.

**2 · `HYPEREVM_RPC_URL not found`.** `foundry.toml` aliases the endpoint through an env var that
the preflight had a default for and `forge` did not. It failed before signing anything, which is
the preflight design working: everything that can fail on configuration fails before the first
broadcast.

**3 · `forge script` cannot broadcast a transaction that reads the precompiles.** It executes the
body of `run()` in its own EVM to build the transactions — including the calls inside
`vm.startBroadcast()` — and that EVM reaches no precompiles, so `bounds()`, `quote()` and `swap()`
all revert with `PrecompileCallFailed` before anything is sent. `--skip-simulation` does not help:
it skips simulating transactions already collected, not the run that collects them. A transaction
that reads HyperCore has to be sent as calldata or from a browser. **Open** → `Swap.s.sol`.

## Also worth knowing

- **Blocks are 3M gas.** `DeskAccount` at `optimizer_runs = 1_000_000` compiled to 18 552 bytes =
  3 710 400 gas of deposit and could not be deployed at all. At 200 runs it is 12 361 bytes and
  fits, for ~5% more gas on the taker: 97 966 against 93 324 → `999_deploy_budget.md`.
- Gas price sat at 0.11–0.21 gwei through both scripts.
- `EIP-3855 is not supported` is a `forge` warning about `PUSH0` on chain 999. Everything deployed
  and runs; noted so it is not rediscovered.
