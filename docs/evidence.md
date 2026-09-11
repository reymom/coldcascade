# The evidence, and its limits

The two bodies of evidence and why they do not add, the replay in full — takers, the modelled book, the dials, the falsifier, the four claims — the v4 hook, and what the repository does not answer.

## Two measurements, and why they do not add

There are two bodies of evidence here and they answer different questions.

| | what it is | what it measures |
|---|---|---|
| **The replay** — 123 minutes of 10 Oct 2025, `forge test --match-contract Oct10Replay` | contracts answering under a tape whose spot and taker volume are real and whose book is modelled | price behaviour against blind takers: what the arbitrageur extracts, what the desk absorbs, how the inventory marks out. There is no perp leg in it |
| **The mainnet path** — chain 999, addresses and hashes above | one real desk, real inventory, real fills | that the quote reads HyperCore, settles through 1inch's router, and that the desk can write an order HyperCore fills |

The replay's markout is the markout of **uncovered** inventory, so it does not sum with the cover
leg. Ignoring funding, fees, basis and spot–perp drift, for a size `q` bought at `P` with a short
opened at `H` and both marked at a common `M`:

```text
spot   = q × (M − P)
short  = q × (H − M)
total  = q × (H − P)
```

`M` cancels. The rebound the markout measures is precisely what the hedge gives up — that is what a
hedge *is*. The replay's edge is what the desk earns by *carrying* the position; the hedge is what
it pays to *not* carry it. The real world is worse than the identity, too: the two instruments
differ, the hedge lands seconds later at a price nobody read, and it can be partial. A hedged
desk's P&L is a third measurement and this repository does not have it yet.


## The replay

- The replay is `forge test --match-contract Oct10Replay -vv`; it writes
  `results/oct10_replay.csv`, whose 54 columns are documented in
  `results/oct10_replay.schema.md`. Five lines: the desk, a plain `XYCSwap` control, the same curve
  charging 30 bps through 1inch's own `FlatFeeIn`, the same curve centred on Hyperliquid's oracle as
  of its last refresh — the maker most people would name as the alternative to an AMM, whose cadence
  `oct10_replay.source` records for the run that produced the file — and Hyperliquid's own touch,
  which is not a maker. Every maker is shipped into Aqua and every fill settles through the official
  router.
- **Both takers are blind, and that is the load-bearing part.** A forced seller walks a pot that is
  a function of the tape alone — the same notional in the quiet as in a cascade — into whichever
  maker quotes best, one clip at a time. An arbitrageur looks, against every maker identically, for
  the round trip that closes profitably at L1's own touch. Neither learns anything about a maker
  beyond the number that came back from `quote`: no regime word, no parameters, no address.
  `test_takers_areBlind` ships the same program into all four slots and requires the four lines
  to come out equal **to the dollar**. They do — $14,226 absorbed and $775,589 of arbitrage
  *notional* each.
  Without that test the rest of the file is a number the harness handed out rather than one a maker
  won, which is exactly what an earlier version of this replay did.
- **The book in the committed run is modelled, and the spot is not.** The CSV is a stub run off
  `tape/oct10_btc_1m.stub.json`: 123 minutes whose `spot` and `takerNtl` are real Coinbase 1m data
  from the 2025-10-10 cascade, and whose `mark`, `bid`, `ask` and forced columns are derived from
  the shape of that price path by `forced_overlay` in `keeper/coldcascade/tape.py`. The quote,
  inventory and fill columns are the contracts themselves answering under it. `oct10_replay.source`
  names the tape and its hash.
- So `SPREAD_GAIN` in that overlay sets how wide a book opens after it has been run over, and the
  desk's price improvement in a lean is bounded by exactly that width. **`test_report_theSpreadIsTheDial`
  measures what it is worth** rather than leaving it as a caveat: at half the tape's spread the desk
  keeps $1,219 and takes 60.8% of the flow, at the tape's own spread $1,306 and 64.8%, at double
  $1,097 and 57.0%. A fourfold range in the one modelled quantity moves the headline across 16% of
  the shipped run, and the shipped width is not an edge of that range: a narrow book leaves less
  distance to lean into and the desk wins less of the flow, a wide one costs more at L1's ask, which
  it pays. The desk's arb notional is zero at every width.
- **The falsifier, and it is on the page rather than in a footnote.** `stressBps` is how far the
  perp book has to walk from oracle before the desk quotes inside L1 — the one decision the extra
  instruction makes. `test_report_theRegimeIsWhatCarriesIt` sweeps it with the map unwired: the
  desk leans on 123, 49, 24, 8 and 0 minutes and absorbs $41,706, $41,706, $36,878, $17,409 and
  **$0**. `test_falsifier_regimeOffCollapsesTheDesk` is that last rung asserted — no reachable
  threshold and no map, and the desk quotes 20 bps outside L1 for 123 minutes and takes **nothing**,
  while the same $56,904 of forced flow goes to the three makers willing to be the best price. It
  also asserts that somebody absorbed it, because a desk that took nothing out of a harness that
  routed nothing would prove the opposite of what it looks like. The shipped 25 bps sits in the
  middle of that range and not at the edge of it, and the arbitrage column is $0 at every rung:
  the regime decides how much the desk trades, the clamp decides none of it is a profitable round
  trip against the book the quote read.
- **On this tape the desk did not need the liquidation map.** The book alone at 25 bps reproduces
  the shipped run to the dollar; raise the threshold past anything the book reaches and leave the
  map wired and the map is worth 3 minutes and $773. That is the best thing that can be said about
  the one input taken on trust — on the day it was built for, it was redundant.
- **Who gets served first inside a minute is an assumption, so it is a parameter and both settings
  are published.** Arbitrageur first is what ships. Serve the forced seller first and in a falling
  market they reach a maker still quoting last minute's higher bid, and the desk wins nothing at
  all — because it will never bid above L1's ask. That is the desk declining to join three AMMs that
  are bidding over the market, and it is exactly where the retired `desk >= 2 x control` gate
  broke: it fails there while the desk is $222 ahead of the best control on what it kept. The desk
  stays ahead under both orderings, by 1.64 bps and 0.24 of the capital deployed, and the threshold
  is set against the shipped one — with the forced seller first the desk absorbs nothing by design,
  so both sides of that comparison are near zero and a threshold on it would be a threshold on which
  of two makers did less.
  `test_report_flowFirstMovesTheShareAndNotTheClaim` runs the retired gate rather than describing
  it, so the example cannot rot into a story.
- Four claims, four tests, and they are different questions.
  `testFuzz_noRoundTripEverProfits` asks whether the quote can ever be arbitraged against the book
  it read, which is the claim that has to hold in every block.
  `test_deathMetric_amountOutMovesWithBook` asks whether a swap responds to the regime at all — a
  program can be perfectly inarbitrable and still be a constant product that ignores L1.
  `test_gate_deskIsNeverArbitraged` asks the first question again at session scale, against an
  arbitrageur that chooses its own size: 123 minutes, both directions, 640 bps of drawdown, nothing
  found. It also fails if the three AMMs are never arbitraged, because then the zero means nothing.
  `test_gate_deskKeepsMoreThanTheControls` asks whether any of it was worth doing: what the desk
  kept, net of what the arbitrageur took, against the **best** of the three controls, in basis
  points of the capital deployed. It is a signed margin and not a multiple, because a multiple has
  no denominator once a control loses money on what it absorbed — which is what a maker priced
  before the trade does in a cascade, and what the two lines priced off their own reserves do here:
  −$34 and −$315 of absorbed edge. The oracle-pegged line is the one that does not, at +$18, and it
  still ends $1,510 behind the desk once the arbitrageur has been paid.
- **The same rule as a Uniswap v4 hook, in `test/v4/`, deployed nowhere.** `test/v4/CoreQuoteHook.sol`
  wraps the deployed `CoreQuote` in a `beforeSwap` with a return delta, `test/v4/PoolManagerStub.sol`
  reproduces v4's delta accounting around it, and `test/CoreQuoteHook.t.sol` asserts that the hook
  and the Extruction agree to the unit over a fuzzed book, that the round trip against L1 still
  never profits, that the same hook without the returns-delta bit leaves the pool's curve paying
  1 352 bps after the 12% move, and that a feed-shaped reader cannot lean. The rule they share is
  `src/libs/Regime.sol:49-68` and `src/CoreQuote.sol:60-110`. What the exercise found is in
  [`FEEDBACK.md`](../FEEDBACK.md).


## What this does not answer yet

**The comparator, and what it costs to make it fair.** The plain constant-product curve is the
weakest baseline there is, so an oracle-anchored maker was built beside it — the same band, the same
curve arithmetic, priced off HyperCore's oracle at its last refresh instead of off the book. On the
mainnet fills it pays **nothing**, exactly like the desk: on ordinary flow with a fast oracle there
is no difference between the two, and the $1.5k the flat curve pays is the drift of this repository's
own demo pool, not a fact about AMMs. In the cascade the same maker pays **$222** and finishes net
negative while the desk finishes ahead, and the dial is published: 60 s costs $222, five minutes
$2,606, fifteen minutes $3,528 — at which point it is indistinguishable from the naive curve. And
the 60 s row is already one refresh per tape minute, so there is no staleness left in it to
remove and the $222 is what remains: the basis. A deviation threshold does not get under it — at
25 bps the same maker pays $294, because a threshold fires on movement and a cascade is movement
it was right to follow. The argument does not turn on which control you pick:
loss-versus-rebalancing is a property of **any** maker whose price is a function of its own reserves
or of a price it read earlier, concentrated liquidity included — Milionis, Moallemi, Roughgarden and
Zhang. A desk whose price is read inside the trade is not in that family.

**Flow that somebody else chose.** Every fill on the demo desk was sent by a schedule in this
repository, which the artifact declares in `source.demand`. That does not weaken the bound — the
clamp is a property checkable on one fill against one receipt, and who stood on the other side does
not enter the arithmetic — but it does mean nothing here measures demand, profitability, or adverse
selection, and this repository does not claim any of the three.

**A hedged desk's profit and loss.** The replay measures price behaviour against blind takers and
has no perp leg, so its markout is the markout of uncovered inventory. Spot and short mark at a
common price and the rebound cancels. That third measurement is not in here.

**The same rule as a Uniswap v4 hook.** `test/v4/` expresses the quote through the hook interface
against a mock reader, and it passes: the interface can carry a maker that prices off an external
book. What is missing is topology, not expressiveness — the venue would have to exist on a chain
whose contracts can read that book in the same call. `FEEDBACK.md` is what came out of writing it.

