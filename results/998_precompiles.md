# The HyperCore precompiles, measured on a live node

**Chain 998, block 63 395 471, 2026-09-04.** Reproduce with `forge build && ./script/probe998.sh`.

The question a fork cannot answer. The precompiles carry no bytecode — `eth_getCode` returns `0x`
for `0x0806`, `0x0807`, `0x0809`, `0x080a` and `0x080e` on both 999 and 998 — so revm executes
nothing and hands back empty data, and every decode in `HyperCore` reverts. Whether a `view`
target reached through `STATICCALL` can read the book, and what a malformed read costs, are
properties of the node.

## A nested read reaches the book, at the same price

`Probe.direct` staticcalls `0x080e`. `Probe.nested` staticcalls itself, which staticcalls
`0x080e` — the shape of router → `CoreQuote` → precompile.

| | bid | ask | precompile frame |
|---|---|---|---|
| `direct(0)` | 1 016 600 | 1 017 400 | 4 296 gas |
| `nested(0)` | 1 016 600 | 1 017 400 | 4 296 gas |

Identical. The extra `STATICCALL` depth costs nothing at the precompile and does not block it, so
`CoreQuote`'s reader is `CorePrecompiles` and reads the live book inside the quote. `BookCache`
stays in the tree as the fallback path the keeper pokes, not as the default.

## What one read costs

| precompile | gas | returns |
|---|---|---|
| `0x0806` `markPx(0)` | 3 235 | 32 bytes |
| `0x0807` `oraclePx(0)` | 3 235 | 32 bytes |
| `0x0809` `l1BlockNumber()` | 2 179 | 32 bytes |
| `0x080a` `perpAssetInfo(0)` | 10 627 | 256 bytes |
| `0x080e` `bbo(0)` | 4 291 | 64 bytes |

A quote reads three of them — BBO, mark, oracle — for about 10 800 gas of node work.

## A bad input burns everything forwarded

This is why the reader caps the frame instead of estimating it. Both a wrong-length input and an
out-of-range perp index consume every gas unit forwarded, return no data, and do not revert with a
reason:

| forwarded | outer frame survived | burned |
|---|---|---|
| 5 000 | yes | 5 117 |
| 30 000 | yes | 30 117 |
| 200 000 | yes | 200 117 |

Uncapped, a bad index inside a quote takes 63/64 of the router's remaining gas. `HyperCore` sets
`PRECOMPILE_GAS_CAP = 30 000`: ~2.8x the most expensive read, so a node-side cost increase does
not turn a good read into a revert, and the damage from a bad one is a bounded 30 123 gas.

## Two things worth knowing before reading an index

`perpAssetInfo` decodes as `(string coin, uint32 marginTableId, uint8 szDecimals, uint8
maxLeverage, bool onlyIsolated)`, confirmed against both chains.

**Perp indices are not the same on the two chains.** Index 0 is BTC on 999 and SOL on 998, so the
numbers above are a SOL book. And an index can exist with no book: index 3 is MATIC on 999 and its
BBO is `(0, 0)` at block 45 029 318 today. A desk quoting off that would be quoting off zero,
which is why `HyperCore.book` reverts `EmptyBook` rather than returning it.

## Reproducing without a funded key

`script/probe998.sh` plants `Probe`'s runtime bytecode at a throwaway address through an
`eth_call` state override, so the code that runs is the code in `src/Probe.sol` and the node that
answers is a real one. It needs an RPC URL and nothing else — no deployment, no faucet, no key.
`script/Probe.s.sol` deploys the same contract for a permanent address; the numbers do not depend
on which path you take.
