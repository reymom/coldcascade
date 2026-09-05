# The desk quoting against the live book, with nothing deployed

**Chain 999, block 45 109 318, 2026-09-05T16:35:15Z.** Reproduce with
`forge build && ./script/probe999.sh`. Needs an RPC URL and no key.

## What was run

`CoreQuote` takes its reader as a constructor argument, so its runtime code is not in the build
artifact — the `READER` immutable is written into it at deployment. It can still be planted on a
node that has never seen it, in three `eth_call`s:

1. a state override puts `CorePrecompiles`' runtime at a throwaway address;
2. an `eth_call` with **no `to`** and `CoreQuote`'s *creation* bytecode plus the encoded reader
   address executes as a contract creation and returns the runtime it would have deployed, with
   the immutable already in it;
3. both are planted in one override object and `bounds()` and `regime()` answer for real.

Nothing is deployed, no key signs anything, and the code that runs is the code `forge build`
produced. Step 2 is the piece `script/probe998.sh` did not need: `Probe` has no constructor
argument, `CoreQuote` does.

## What it answered

| | bid | ask | mark | oracle |
|---|---|---|---|---|
| **L1**, raw | 799 500 | 799 510 | 799 510 | 799 792 |
| **L1**, USD | $79,950.0 | $79,951.0 | $79,951.0 | $79,979.2 |
| **desk**, raw | 797 901 | 801 110 | | |
| **desk**, USD | $79,790.1 | $80,111.0 | | |

Canonical parameters: quiet 20 bps, lean 15 bps, stress 25 bps, book-only (no map oracle).
`regime()` reports a dislocation of **3 bps** and no map, so `lean = none`: the desk sits 20 bps
outside L1 on both sides and is not the best price on the screen. `797 901 = ⌊799 500 × 9 980 /
10 000⌋` and `801 110 = ⌈799 510 × 10 020 / 10 000⌉`, which is `_mulBps` and nothing else.

That is the whole quiet-regime claim, answered by the deployed-shaped contract against the book
the exchange is running on, three days before the desk holds a token.

## The precompiles ignore the block tag

The same `0x080e` read, pinned to three different blocks in the same run:

| block tag | bid | ask |
|---|---|---|
| latest | 799 500 | 799 510 |
| 2 000 back | 799 500 | 799 510 |
| 200 000 back | 799 500 | 799 510 |

Identical. **The precompiles are node state, not chain state**: they answer from HyperCore now,
whatever block the EVM call is pinned to. There is no archive read of the book and no way to ask
what it was.

Two consequences, both load-bearing.

- **`BookCache` is not a fallback, it is the only history.** A markout needs the book at t+5, t+15
  and t+60 minutes after a fill. That quantity does not exist unless somebody wrote the words into
  a log while they were current, which is what `poke` does and why the keeper runs it on a cadence.
  The `Fill` event carrying its own book is the same argument at the moment of the fill.
- **Two reads are two different books.** A page that calls `read()` and then `bounds()` can draw an
  L1 band and a desk band that never coexisted — a 10-raw tick is enough to make the arithmetic on
  screen look wrong. `FloorLens.floor()` exists so the console takes its whole snapshot in one
  `eth_call` and the four numbers agree by construction.
