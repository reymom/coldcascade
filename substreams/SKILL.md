# coldcascade — reading the desk's data

A guide for an agent that needs to answer questions about this desk from its own record. It
assumes nothing about the contracts beyond what is here.

**What the desk is, in one paragraph.** coldcascade is a 1inch Aqua maker program on HyperEVM
(chain 999). When a taker swaps against it, the program reads Hyperliquid's L1 order book from the
HyperCore precompiles *during* the swap and bounds its own quote against it. Because the read
happens inside the trade, every fill emits the book it was priced against, in the same log. That
is what makes the desk's history answerable at all, and it is what this package reads.

---

## Endpoint

```
hyperevm.substreams.pinax.network:443
```

The Graph Market for Substreams; the HyperEVM provider is Pinax. Auth is a bearer token in
`SUBSTREAMS_API_TOKEN` (this repo's `.env` calls it `PINAX_JWT`). There is **no hosted subgraph for
chain 999** — Subgraph Studio reports `hyper-evm: subgraphsSupportLevel: "none"` — so Substreams is
not one option of two, it is the path that exists.

## Package

`substreams/coldcascade-v0.1.0.spkg`, network `hyperevm`, first block **45 135 453** (the
deployment). Rebuild with `cargo build --release --target wasm32-unknown-unknown && substreams pack
substreams.yaml`.

| module | kind | output | hash |
|---|---|---|---|
| `index_desk_events` | index | `sf.substreams.index.v1.Keys` | `7b3dd993…` |
| `desk_events` | map | `coldcascade.v1.DeskEvents` | `d41fe4eb…` |

`desk_events` carries a block filter over the index —
`contract:deskhooks \|\| contract:bookcache \|\| contract:maporacle \|\| contract:markoutledger` —
so a scan from the first block to head is a quarter of a million HyperEVM blocks and a couple of
dozen messages. Blocks containing none of the four contracts are never emitted.

## Running it

```
export SUBSTREAMS_API_TOKEN=...
substreams run -e hyperevm.substreams.pinax.network:443 \
  substreams/coldcascade-v0.1.0.spkg desk_events \
  -s 45135453 -t 0 -o jsonl --limit-processed-blocks 0
```

`--limit-processed-blocks 0` is required: the CLI refuses ranges over 10 000 blocks without it.
`-o jsonl` gives one JSON object per line, which is what the reference consumer parses.

---

## Output shape

One `coldcascade.v1.DeskEvents` per block that had something in it:

```json
{ "blockNumber": "45195770", "blockHash": "0xe5e61b29…", "timestamp": "1788711150",
  "fills": [ … ], "books": [ … ], "maps": [ … ], "markouts": [ … ] }
```

**`fills`** — `DeskHooks.Fill`. The four book words are what the quote read while pricing *this*
swap. `tokenIn`/`tokenOut` and `amountIn`/`amountOut` are the taker's legs as the router sees them,
so the desk received `amountIn` of `tokenIn` and paid `amountOut` of `tokenOut`.

```json
{ "txHash": "0xfaf1b6c6…", "logIndex": "35",
  "orderHash": "0xa0f7ca13…", "maker": "0xc76137e4…", "taker": "0x9d597ddf…",
  "tokenIn": "0x42e5aab5…", "tokenOut": "0xb89d8429…",
  "amountIn": "1000000", "amountOut": "795396020",
  "bid": "796990", "ask": "797000", "mark": "796980", "oracle": "797210",
  "mapBelow": "0", "mapAbove": "0", "bookOk": true }
```

`orderHash` is Aqua's **strategy** hash. It names the program, not the fill — every fill a desk
makes carries the same one — so it is not a key. `bookOk` is false when all four words are zero:
the hook is fail-soft by design, so a book it could not read is a fill to skip, not a fill priced
at zero. Prices are raw L1 units, scale `10^(6 − szDecimals)`; for BTC divide by 10 for USD.

**`books`** — `BookCache.Booked`: the L1 book written into a log while it was current, by a
permissionless `poke`. This exists because the HyperCore precompiles **ignore the block tag** — an
`eth_call` pinned two hundred thousand blocks back returns the *current* book. They are node state,
not chain state, so there is no archive read for them and no way to ask what the book was. The
series began at `0x24dbe446…b60d`, block 45 357 494, on 8 Sep 2026; before that there was not one
`Booked` event on chain 999.

**`maps`** — `MapOracle.MapUpdated`, the one input the desk takes on trust.

**`markouts`** — `MarkoutLedger.Markout`, what the keeper computed and wrote back. Reading these is
how the keeper knows what it has already published; `post` emits and does not store, so the log is
the record and it cannot be restated.

---

## Questions this answers

| question | how |
|---|---|
| What was the L1 book when a given fill happened? | `fills[].bid/ask/mark/oracle` — it is in the fill itself, no join |
| Where did a fill print against the L1 touch? | `(execPx − touch) / touch`, where `execPx = amountQuote/amountBase × pxDen/pxNum` and `touch` is the bid when the desk bought base, the ask when it sold |
| Did the bound set that price, or the curve? | the bound sets it exactly at ±`quietBps`; anything further out is the curve. See *the two regimes* below |
| Was the desk under stress at that moment? | `\|oracle − mark\| / oracle` per fill, against the maker's `stressBps` |
| What did L1 do in the N minutes after a fill? | join the fill to the first `books[]` entry at or after `t + N`, within tolerance |
| What has the keeper decided? | `markouts[]`, and `results/markouts.json` for the same thing joined up |
| Is the book series healthy right now? | gaps between consecutive `books[]` timestamps; one poke a minute is the target |

### The two regimes

A fill prints either at exactly ±`quietBps` or well outside it, and this is one rule, not two
behaviours: in the quiet regime the taker receives `min(curve, bound)`. The bound caps how *good*
the desk's price may get and never improves it, so it sets the price only when the desk's own
constant-product curve wanted to deal inside the band. Which happens depends on where the pool sat
against L1 when the fill arrived, and on size — a large enough take walks the curve through L1
inside the trade.

That variable is **not in the `Fill` event**. It needs the desk's two token balances at
`block − 1`, and the public RPC cannot supply them: it accepts a past block tag and returns
*current* state, so a reserve read there is silently the wrong number rather than an error. Use an
archive endpoint (`hyperliquid.drpc.org` and `rpc.purroofgroup.com` both work; measured in
`results/999_state_at_a_past_block.md`). The L1 price to compare against is the fill's own `oracle`
word, already in the log.

## What this does not answer

- **Whether a maker is unbacked.** Aqua's virtual balances live in its own `Shipped` event, which
  this package does not decode.
- **Whether the desk is leaning right now.** The regime is computed inside `CoreQuote` and is not
  emitted; it can only be inferred per fill from `oracle` against `mark`.
- **A hedged desk's P&L.** The perp leg is on HyperCore, not in any EVM log here.

---

## How an agent consumes it

`keeper/coldcascade/markouts.py` is the reference consumer and is deliberately small: standard
library and `cast`, no sink, no Postgres, no Docker. `substreams run` already speaks JSON lines.

1. **Stream** — subprocess, parse `@data` per line (`keeper/coldcascade/substreams.py`).
2. **Cache** — blocks older than the last 400 come from disk. A full scan is 225 000 blocks, four
   minutes and 81 MiB of egress; the cached pass is nine seconds. A cache is a claim about history,
   so the tail is always re-read.
3. **Join** — each fill to the first book at or after `t + 5`, `t + 15`, `t + 60` minutes, and only
   if one landed inside a tolerance: the larger of two poke intervals and a tenth of the horizon.
   Without that bound a fill from before the series started gets marked against a book five hours
   later and labelled five-minute.
4. **Decide and write** — `MarkoutLedger.post(orderHash, fillId, horizonMinutes, bps)` from the
   poster. `fillId` is the transaction hash with its last four bytes replaced by the log index,
   because `orderHash` names the program rather than the fill.
5. **Read the decision back** — the same module decodes `Markout`, which closes the loop and is
   what makes the keeper idempotent.

```
python -m coldcascade markouts            # stream, join, write results/markouts.json
python -m coldcascade markouts --post     # and send what is new
```

## The derived artifact

`results/markouts.json`, served at
[`coldcascade.vercel.app/results/markouts.json`](https://coldcascade.vercel.app/results/markouts.json).
Read this first if the question is about aggregates; stream the module if it is about a specific
fill or block.

- `source` — endpoint, package, module, block range, and **how the flow was generated**
- `summary.bySide` / `summary.byDesk` — counts and stats split by side and by desk, each with
  `atTheBand` measured against that desk's own frozen `quietBps`
- `fills[]` — per fill: `vsTouchBps`, `poolDevBps`, `quietBps`, and `markouts` at each horizon
- a horizon with no number says *which kind* of nothing it is: `pending` resolves in minutes,
  `beforeSeries` never resolves because the fill predates the first poke, `gap` never resolves
  because the series had a hole, `noBook` is a fill whose own book the hook could not read

### Read the markout for what it is

**The demand on this desk is scripted.** `script/demo-cadence.sh` sends a take every twenty
minutes, choosing side and size from the pool's own drift and the desk's inventory. So a markout
here is **not** a measurement of adverse selection, and nothing derived from it is an edge claim:
with flow this desk generated itself, at times a cron chose, the number is post-fill drift of BTC
sampled at arbitrary hours. It is in the artifact because it proves the keeper loop runs
end to end — stream, join, decide, write, read back — which is the thing worth demonstrating.

The argument about the mechanism rests on `vsTouchBps` instead, and deliberately: a fill printing
at its maker's `quietBps` to the basis point is a **property of the program**, checkable on a single
transaction against a receipt, not a statistic that needs a sample to mean anything.
