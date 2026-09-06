# `oct10_replay.csv` — the columns

One row per minute of the tape, in tape order, written by `test/Oct10Replay.t.sol`:

```
forge test --match-contract Oct10Replay -vv
```

The header in the file is the schema. It is frozen: `test_replay_writesResults` fails if the file
does not carry it verbatim, `app/src/types.ts` mirrors it field for field, and
`keeper/coldcascade/plot.py` reads it by name.

## Units, once

| kind | unit |
|---|---|
| prices (`spot`, `bid`, `ask`, `mark`, `oracle`, `deskBid`, `deskAsk`) | raw HyperCore. `price = raw / 10^(6 − szDecimals)`; BTC has szDecimals 5, so raw ÷ 10 is USD |
| notionals (`*Ntl`) | whole USD |
| `base*` | UBTC units, 8 decimals |
| `quote*` | USDT0 units, 6 decimals |
| `*Bps` | signed integer basis points |
| `t` | unix seconds, minute open |

## The columns

| # | column | meaning |
|---|---|---|
| 1 | `t` | minute open |
| 2 | `spot` | Coinbase BTC-USD close. What both inventories are marked at |
| 3–6 | `bid` `ask` `mark` `oracle` | the L1 book that minute, as the desk read it |
| 7–8 | `deskBid` `deskAsk` | the desk's own two prices, from `CoreQuote.bounds()` under that book |
| 9 | `lean` | 0 none, 1 bid, 2 ask — which side is absorbing |
| 10 | `dislocationBps` | `(oracle − mark) · 1e4 / oracle`; positive is the book below oracle |
| 11–12 | `mapBelowNtl` `mapAboveNtl` | what the liquidation map said, per side |
| 13–14 | `forcedSellNtl` `forcedBuyNtl` | forced flow that actually hit the book this minute |
| 15–16 | `baseDesk` `quoteDesk` | desk inventory after the minute |
| 17–18 | `baseControl` `quoteControl` | plain-`XYCSwap` control inventory after the minute |
| 19–20 | `pnlDeskBps` `pnlControlBps` | inventory marked at `spot`, against the starting value, in bps. **The two lines on the screen** |
| 21–22 | `absorbedDeskNtl` `absorbedControlNtl` | forced flow each maker took this minute |
| 23–24 | `arbDeskNtl` `arbControlNtl` | notional the arbitrage taker extracted from each maker |
| 25–27 | `markoutDesk5mBps` `markoutDesk15mBps` `markoutDesk60mBps` | this minute's desk fills against spot 5, 15 and 60 minutes later; positive is the maker being right |
| 28–30 | `markoutControl5mBps` `markoutControl15mBps` `markoutControl60mBps` | the same for the control |
| 31–32 | `baseHard` `quoteHard` | hardened-control inventory after the minute |
| 33 | `pnlHardBps` | the same mark as `pnlDeskBps`, for the hardened control |
| 34–35 | `absorbedHardNtl` `arbHardNtl` | flow it took, and notional the arbitrageur traded against it |
| 36–38 | `markoutHard5mBps` `markoutHard15mBps` `markoutHard60mBps` | the same for the hardened control |
| 39 | `absorbedTouchNtl` | the whole minute's pot, as if it had gone to L1's touch instead of to a maker |
| 40–42 | `markoutTouch5mBps` `markoutTouch15mBps` `markoutTouch60mBps` | that pot marked out from L1's own bid (forced selling) or ask (forced buying) |
| 43–45 | `lvrDeskNtl` `lvrControlNtl` `lvrHardNtl` | **what the arbitrageur actually took out of each maker**, in USD, closed at L1's touch |

## The four lines

| line | program | what it is for |
|---|---|---|
| desk | `XYCSwap ‖ Extruction(CoreQuote, params) ‖ Salt` | the thing being measured |
| control | `XYCSwap ‖ Salt` | the **ablation**: `desk` with one instruction removed, so a difference between the two is that instruction and nothing else |
| hardened control | `FlatFeeIn(3 000 000) ‖ XYCSwap ‖ Salt` | the **competitor**: the same curve charging 30 bps, which is what people deploy. Built out of 1inch's own `Fee` instruction rather than an AMM written here, because a control you wrote yourself is a foil |
| L1 touch | not a maker | the **benchmark**: the same flow at Hyperliquid's own bid and ask. No inventory, never arbitraged, takes the whole pot rather than competing for it |

The fee is in the router's unit, not in basis points: the deployed revision's `Fee` uses
`BPS = 1e9`, so a basis point is 100 000 and 30 bps is 3 000 000. `FlatFeeIn` also comes **before**
the curve — it drives the rest of the program through `runLoop` and reverts if a leg is already
written — so `XYCSwap ‖ FlatFeeIn` builds a revert, not a fee'd AMM.

Both AMM lines are in the same race, which means they take flow from each other as well as from
the desk. Read `absorbedDeskNtl` against the **sum** of the two, not against either alone.

A markout is zero rather than missing when the minute had no fill, or when the tape does not reach
5, 15 or 60 rows past it. The second case is only allowed to happen inside the tail: the tape runs
at least 60 minutes past its own last fill, `select_window` in `keeper/coldcascade/tape.py` cuts it
that way, and `test_tape_coversTheLongestMarkout` fails if it does not. The fix when that test
fails is a longer tape, never a shorter horizon — the minutes after a cascade are exactly where
the desk is holding what it caught, and cutting them shows only the half of the trade that loses.

`mapBelowNtl` and `forcedSellNtl` are different quantities that a stub run happens to set equal.
The map is *resting* forced notional within 1% of mark, rebuilt by the keeper; the forced columns
are flow that already traded. They separate as soon as the real map builder runs.

## Derived, and deliberately not a column

The number the whole comparison rests on is not in the file, because it does not need to be:

```
absorbed edge = Σ  markoutDesk60mBps / 10 000 × absorbedDeskNtl
```

and the same against each of the other lines. A markout in basis points is a *rate*, and the desk is
supposed to lose on that rate — leaning inside the spread means paying up, on every fill, by
construction. What it buys is size at a price that reverts, so the quantity that carries the
argument is the rate applied to the notional actually absorbed. Both terms are already columns, so
the page and `test_absorbedEdge_isReportedAsAPair` each compute it and the schema did not have to
move.

`oct10_replay.source` records, for whatever run produced the file, each line's absorbed notional,
its absorbed edge, the LVR it paid and the notional the arbitrageur traded against it.

The number that does not degenerate is the LVR column. A ratio of absorbed edges stops existing
the moment the control's edge goes negative — which is what a maker priced before the trade does
in a cascade — so the file carries the pair, and the gate is a signed margin rather than a
multiple. See `test_gate_deskKeepsMoreThanTheControls`.

## Provenance

`oct10_replay.source`, written by the same test, names the tape the CSV came from, its
`keccak256`, its length, and each line's session totals.

**The committed CSV is a stub run**, off `tape/oct10_btc_1m.stub.json`. Three layers, and they
are not equally real:

| layer | source |
|---|---|
| `spot`, `oracle`, `takerNtl` | **real.** Coinbase BTC-USD 1m closes and volume, 2025-10-10 21:03 → 23:05 UTC, pulled 2026-09-05. The trough on the tape is $107 600 at 21:21; Coinbase's low for the day was $107 000 at 21:26 |
| `mark`, `bid`, `ask`, `forcedSellNtl`, `forcedBuyNtl` | **synthetic.** `forced_overlay` overshoots mark off oracle in the direction of recent momentum and widens the book with recent movement in excess of the session's baseline — both decaying, because a dislocated perp stays dislocated and a book that has been run over comes back slowly. A minute counts as forced when it moves more than eight times the session's own median. The fill log that would replace all of this is on S3 and requester-pays |
| `deskBid`, `deskAsk`, `lean`, `dislocationBps` | **the contract.** `CoreQuote.bounds()` and `.regime()` answering under the row's book — not a model of the quote, the quote |
| everything else | **settled.** Every maker is shipped into Aqua and every fill goes through the official router, so the inventory, absorbed, arbitrage and markout columns are what the contracts actually did to each other under the book above — real arithmetic over a modelled book, which is a different thing from a modelled result |

The one modelled quantity the headline depends on is the width of that book: the desk's price
improvement in a lean is bounded by the distance from L1's bid to L1's ask, and `SPREAD_GAIN` in
the overlay sets it. `test_report_theSpreadIsTheDial` re-runs the whole session at half and double
the tape's own spread and reports what moves — 9% of the desk's kept dollars across a fourfold
range, *against* the desk as the book widens, and an arb notional of zero at every width. Regenerate
the tape with:

```
python -m coldcascade tape --stub
```
