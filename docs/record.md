# The desk's own record, and the MCP server over it

Why the book has to be written down, the Substreams package, the markout keeper and its tolerances, what the record shows so far, and the MCP server that serves the archive.

## The desk's own record

Every fill this desk makes already carries the book it filled against — `DeskHooks.Fill` emits
bid, ask, mark and oracle as `CoreQuote` read them while pricing that swap. So the desk's history
is not a thing that has to be reconstructed. It has to be *read*, and then joined to what the book
did next.

The second half is the hard one, and it is why `BookCache` exists. The HyperCore precompiles
**ignore the block tag**: an `eth_call` to `0x080e` pinned two hundred thousand blocks back answers
with the current book (`results/999_precompile_block_tag.md`). They are node state, not chain
state. There is no archive read and no way to ask what the book was fifteen minutes ago — unless
somebody wrote the four words into a log while they were current. `BookCache.poke` is that, it is
permissionless, and `script/poke-cadence.sh` calls it once a minute for 50 642 gas.

**`substreams/`** is a Rust Substreams package decoding `Fill`, `Booked`, `MapUpdated` and
`Markout` out of HyperEVM blocks. `index_desk_events` writes one key per contract that spoke in a
block; `desk_events` filters on it, so a scan from the desk's first block to the head is a quarter
of a million HyperEVM blocks and about twenty messages. It runs against The Graph Market for
Substreams — Subgraph Studio reports `hyper-evm: subgraphsSupportLevel: "none"`, so there is no
hosted subgraph on chain 999 to deploy to, and the Substreams provider is the path that is open.

`results/999_substreams_fill_decode.md` sets the module's decode of `0xfaf1b6c6…ab20` beside the
receipt the node serves for it: eleven data words and two indexed topics, all equal.

**`keeper/coldcascade/markouts.py`** consumes that stream, joins each fill to the first book at or
after `t+5`, `t+15` and `t+60` minutes, and posts the result to `MarkoutLedger`, whose `Markout`
log the same module decodes on the next pass. That is what stops the keeper restating a number it
has already published: it reads what it said from the chain, not from its own memory.

```
python -m coldcascade markouts            # stream, join, write results/markouts.json
python -m coldcascade markouts --post     # and send what is new
```

A horizon counts only if a book landed inside its tolerance, which is **the larger of two poke
intervals and a tenth of the horizon**: 120 s at 5 and 15 minutes, 360 s at 60. A flat bound does
not mean the same thing at both ends — three minutes late is a 60% error on a five-minute markout
and 5% on a sixty-minute one — so the tenth is what binds once the horizon is long enough, and
below that the floor binds, because the series is written one poke a minute and asking for better
than it can supply only discards fills. At five minutes the floor is 40% of the horizon; the
*actual* lag is normally under a minute, and every horizon in the artifact carries its own
`lagSeconds` and `toleranceSeconds` so this is checkable rather than promised.

Without the bound at all, a fill from before the series started would be marked out against a book
five hours later and labelled five-minute, which it is not.

A horizon with no number says which kind of nothing it is, because a page that draws them the same
way is misleading in the one place it matters: `pending` resolves itself in a few minutes,
`beforeSeries` never resolves because the fill predates the first poke, `gap` never resolves
because the series had a hole there, and `noBook` is a fill whose own book the hook could not read.
`summary.byHorizon` in `results/markouts.json` carries the count in each state, and it is not
repeated here because the cadence moves it every twenty minutes — the eight `beforeSeries` are the
one part of it that is fixed, being the fills that predate the series and can never acquire one.

**What the number is, and what it is not.** The demand on this desk is scripted:
`script/demo-cadence.sh` sends a take every twenty minutes and picks its side and size from the
pool's own drift and the desk's inventory. Nobody trades against this desk because they thought the
price was wrong. So a markout here is the signed move of L1 mid over a fixed horizon and nothing
more — post-fill drift of BTC, sampled at hours a cron chose. It is **not** a measurement of
adverse selection, which is a claim about who traded and why, and here the answer to both is us.
It is not a yield, and it is not the desk's P&L: it ignores the spread captured at the touch, which
is reported separately per fill as `vsTouchBps`, and it ignores the perp leg entirely, for the
reason in *Two measurements* above.

**What it does demonstrate is the loop.** Read the stream, join a fill to a later book, decide a
number, write it to the chain, and read that decision back off the same stream on the next pass.
Every markout posted exercises all five steps, and that is the reason to compute them at all.

The argument about the mechanism does not rest here. It rests on `vsTouchBps` below, and
deliberately: a fill printing at its maker's own `quietBps` to the basis point is a **property of
the program** — checkable on one transaction against one receipt — rather than a statistic that
needs a sample before it means anything. The `source.demand` block in `results/markouts.json` says
the same thing to anything that reads the artifact without reading this.

**What exists so far.** Every fill on chain 999 is one we sent, and they fall into two groups
that look like two behaviours and are one rule. Some print at exactly ±`quietBps` against the L1
touch; the rest print well outside it.

The rule is a single line of `CoreQuote`: in the quiet regime the taker receives
`min(curve, bound)`. The bound caps how *good* the desk's price is allowed to get and never makes
it better, so it sets the price only when the desk's own constant-product curve wanted to deal
inside the band. Which of the two happens is decided by where the pool sits against L1 when the
fill arrives — `poolDevBps` in the artifact: the pool's implied price of base over **L1's oracle**,
in bps. `keeper/coldcascade/markouts.py` measures it against the fill's own oracle word, so every
`poolDevBps` on this page carries that denominator and not the bid:

| pool against L1 | the desk buying base | the desk selling base |
|---|---|---|
| **above** (base dear in the pool) | curve would overpay → **bound sets it, ±`quietBps`** | curve already dearer than L1 → **curve sets it** |
| **below** (base cheap in the pool) | curve already cheaper → **curve sets it** | curve would undersell → **bound sets it, ±`quietBps`** |

Two named transactions, both mainnet, both in the artifact:
[`0xfaf1b6c6…ab20`](https://hyperevmscan.io/tx/0xfaf1b6c68aeae9eaed9ff49acc54d0ac7081f1537b602f5609679238c22dab20)
is a purchase with the pool 160.8 bps above L1's oracle (`poolDevBps`) — the bound bit, and the fill
printed at −20.0000 bps, which is measured against the **touch**.
[`0x9407579f…537c`](https://hyperevmscan.io/tx/0x9407579f28988f85c0655637d5437476bf5371b59de63602b13936b10993537c)
is a sale with the pool 46.5 bps above L1's oracle — nothing to cut, and the curve priced it at
+111.2 against the touch.

Size decides how much cushion the table's first column actually has, because a take large enough
walks the curve *through* L1 inside the trade. One purchase against a pool only 63.7 bps above L1
printed at −94.7 rather than at the band: 3 327 697 raw base in, 1.65% of the desk's reserve, and
the 2 568 453 650 quote it paid is `q·Δ/(b+Δ)` on the pre-trade reserves **to the unit**. The plain
curve, exactly, with the bound standing aside — which is `min(curve, bound)` choosing the curve,
not the bound failing. It is also why the band is a floor on the desk's edge and not a description
of it.

`summary.bySide` and `summary.byDesk` in `results/markouts.json` carry the counts and never go
stale, which is why they are not repeated here. `atTheBand` is measured against each desk's own
frozen `quietBps`, not against a hardcoded 20. The desks are kept apart because they are not one
population: the demo desk trades a mintable pair and is the tape, while the hedged desk is
deliberately lopsided from absorbing base and sits thousands of bps off L1.

Reserves at a past block come from an archive endpoint, because the public node cannot answer:
`balanceOf` at four blocks 145 000 apart returns the *current* balance every time. The block tag is
accepted and ignored, exactly as it is for the HyperCore precompiles — the same property that made
`BookCache` necessary in the first place, met a second time on ordinary contract state.

The `Booked` series began at 12:23:43Z on 8 Sep
(`0x24dbe446…b60d`, block 45 357 494); before that `pokedAt(0)` was 0 and there was not one
`Booked` event on the chain. **Every fill older than that series has no right-hand side to join
to, and carries no markout.** The record starts where the series starts, and it is short.

## Serving it: an MCP server over the stream

`mcp/` is a Model Context Protocol server over the same package. It exposes two things.

**The book archive**, which is the part no RPC can serve. `get_book_at_time` and
`get_book_at_block` answer *what Hyperliquid's BBO was* at a past moment on chain 999 — the
question the HyperCore precompiles refuse, since they accept a block tag and return the present.
That instant is queryable only because `poke` wrote it into a log while it was true.

**The desk's record**: `get_fill` returns one fill with the book it met, `vsTouchBps`,
`poolDevBps`, the desk's `quietBps`, its markouts, and a sentence saying whether the bound or the
curve set that price. `list_fills` filters by desk, side and which rule priced them;
`get_markouts` returns the keeper's decisions with their statuses and whether each is on chain;
`describe_coverage` states the extent, the density, the holes, and what the server cannot answer.

Three properties are load-bearing and are what the tests pin:

- **Nothing is interpolated.** A moment between two pokes returns both neighbours with their
  distances and `interpolated: false`, plus a warning when the bracket is wider than the cadence.
  The truth is inside the bracket; the server does not guess where.
- **Absence keeps its four names** — `beforeSeries`, `gap`, `pending`, `noBook` — because they
  mean different things and only one of them ever resolves.
- **Every response carries `provenance`** with a `reproduce` command that regenerates it from the
  stream and a `cast` command that checks it against the chain.

It returns observations and their limits, and it says in its own instructions that it does not
produce trading advice. Standard library only, so it runs with a stock Python and no install
step. `mcp/SKILL.md` is the manual, and the server serves it at `coldcascade://skill`.

**It has its own way to the stream, and it ships with a corpus.** `results/desk-events.jsonl` is a
committed snapshot of the decoded stream, so a clone answers every tool above with no credentials
and no network, and `describe_coverage` says it is a snapshot and which block it stops at. With a
free Substreams key from The Graph Market, `sync_stream` runs the package against Pinax and brings
the corpus to the chain head, reporting how many blocks crossed the network and from where. It is
the keeper's own `cached_stream`, imported rather than copied, so what a reader runs is what the
cadence runs. The only node call the server makes is one `eth_blockNumber`, to know where to stop;
it never asks a node for a book, which is the query a node cannot answer.

`results/book-archive.json` is the same series as a static file, so the console can answer the
same question in the browser from the same numbers.

