# coldcascade

A maker program on 1inch Aqua whose quote is computed from Hyperliquid's own order book inside the
call that settles the swap. It has no stale price, so there is nothing on it to arbitrage.

That is the problem it is built against. An automated market maker is arbitraged for the distance
between its price and the reference venue's, because its price was set before the trade that takes
it. The arbitrageur's profit is the LP's loss, it has a name — **loss-versus-rebalancing** — and
fees are what an LP has to cover it with. Fees shrink it and faster blocks shrink it, but nothing
in the shape of an AMM takes it to zero, because the gap between quoting and being taken is where
the whole construction lives.

A maker that reads the reference book in the same call has no such gap. This one reads it and then
clamps itself to what crossing L1 would have paid, so the round trip against L1 is negative in the
quiet by the desk's own band, exactly zero while it is leaning, and positive never.

**HyperEVM is not the argument. It is where the argument is possible today** — the one chain with
1inch Aqua deployed and a perp book a contract can read in the same call: `0x0806` mark, `0x0807`
oracle, `0x080e` best bid and ask, as precompiles. Aqua's HyperEVM deployment has no makers. This
is the first program that quotes against that book.

The program is `XYCSwap || Extruction(CoreQuote)` on the official SwapVM router. `CoreQuote` reads
the book in the quote itself, and Aqua custodies nothing.

**Absorbing a liquidation cascade is the same property under stress**, and it is the consequence,
not the thesis. When the book dislocates from oracle, or a fresh liquidation map says mark is
walking into forced flow, the absorbing side moves from outside L1 to L1's own price and warehouses
the overshoot: the same clamp, reached from the other end. The desk becomes the best price on the
screen for whoever is being forced out and is still not arbitrable. That half pays twice a year.
The half above is true in every block.

## It cannot be arbitraged

One round trip, priced entirely off the same book the quote read: take the desk's price, close the
position at L1's own touch. On chain 999 at block 45 117 336, 2026-09-05T18:46:42Z, the canonical
parameters answered against a live L1 bid of 799 290 and ask of 799 300:

| the round trip | desk price | closed at | result |
|---|---|---|---|
| buy base from the desk, sell it into L1's bid | 800 899 | 799 290 | **−20.09 bps** |
| sell base to the desk, buy it back at L1's ask | 797 691 | 799 300 | **−20.13 bps** |

L1's own spread was 0.13 bps of that, and the exit has to cross it. `./script/probe999.sh` is those
prices from a shell with no key and nothing deployed; the Floor recomputes them every two seconds
and puts the better of the two directions — the arbitrageur's best case — in its header.

**The property is asserted, not described.** `test/Inarbitrable.t.sol` runs the same round trip
against `CoreQuote.extruction`, which is the code path the router settles through and not a display
helper. It never returns more than went in: either side, exact-in or exact-out, with or without a
curve ahead of the bound, over a fuzzed book, with the lean driven by the book or by a map oracle
that is lying, and with every rounding handed to the arbitrageur. The exit is priced at L1's touch
with no fee and no depth limit, which is a better exit than any that exists.

`test_lvr_theControlIsArbitrableAfterAMove_theDeskIsNot` is the whole argument in one test. Two
makers on 1inch's router, same pair, same inventory, both priced at the book they were shipped at.
The book then moves 12%, which is the 10 October 2025 move. The control is a constant product and
has not heard about it, so an arbitrageur now takes **1 352 bps** out of it in a single round trip.
The desk carries *the same constant product* — `XYCSwap` runs first in its own program and its
curve wants to pay that same stale price — and the bound cuts 794 715 284 units of quote back to
700 010 000, which is L1's own offer to the last unit. **Zero, not negative:** the desk is never a
better price than crossing L1, and never worse than useless.

**What this does not claim.** That the desk cannot lose. It can, and in the ordinary way: the
reference price moves after a fill, which is inventory risk — what the markout measures and what
the cover leg is for. It also inherits HyperCore's book, so if that book is wrong against the rest
of the world the desk is wrong with it. LVR is the loss to somebody holding a better price than
yours *at the same instant*. That one is zero here by construction.

## The desk is a contract

`DeskFactory.open` deploys a `DeskAccount` — an EIP-1167 clone owned by the caller — and in the
same transaction moves the maker's two tokens into it, approves Aqua and ships the strategy. The
account is the Aqua maker. Its owner has four typed calls: `reopen`, `close`, `withdraw`,
`armHedge`. `close` is one call that docks the strategy and sends everything home.

It is not a vault: no pooling, no shares, no third party, no fee, no admin, no upgrade. What it
costs is that the maker's tokens sit in a contract the maker owns rather than in the wallet. What
it buys is a desk with an address — something a name can point at, an indexer can address, and a
margin account can belong to. A plain EOA maker still works; the tests ship the control from one.

Aqua keys a strategy by the hash of its bytes and refuses one it has already seen, and docking
does not free the key. So parameters are immutable per strategy, a parameter change is a dock and
a fresh ship, and every ship carries a per-account salt.

`DeskHooks` is the single post-transfer-out hook and the single `Fill` emitter: the four L1 words
and the liquidation map go into the log beside the amounts, so a markout can be computed from
indexed data alone. **It emits the fill and stops.** It makes no call to the maker, so a maker
whose every entry point reverts is still filled — and, more to the point, a maker feature is not a
taker cost. A swap against a contract maker costs 97 966 gas and one against an EOA maker 97 993:
the contract is the cheaper of the two, because there is no callback in the bill.

Cover happens in the desk's own transaction. `DeskAccount.cover()` — owner, or an operator the
owner names in `armHedge` — reads how much base the desk has accumulated since it was last square,
values it at mark, caps it at the armed ceiling and emits the intent. 42 138 gas, paid by the
desk. Exposure is `balanceOf(base) - coveredBase` rather than a fill, because the account cannot
verify a fill: logs are not readable from the EVM, and a watcher that handed it fill amounts would
be a watcher that could size a real L1 order. The delta also nets — a desk that bought and sold
back covers once.

What that costs: the contract no longer knows whether a fill was on the absorbing side, so *when*
to cover is the operator's decision under the owner's ceiling, not a rule in the code. The
contract still takes no view on the sign — long base sells the perp, short base buys it.

## The console

One URL. The Floor leads with the round trip above — recomputed off the live book every two
seconds, and the reason the quiet screen is the evidence rather than the absence of it. Under it:
Hyperliquid's BTC book as `CoreQuote` reads it, the desks quoting against it, a map button that
puts a desk into a lean so the other half is on the screen on demand, and a Take button that swaps
through the official router. It is live before the contracts are:
where nothing is deployed, `CorePrecompiles`, `CoreQuote` and `FloorLens` are planted at throwaway
addresses by an `eth_call` state override and the canonical parameters are priced against the real
book. The bytecode is what `forge build` produced and the node running it is a real one —
`./script/probe999.sh` is the same three calls from a shell, and `results/999_live_quote.md` is what
they answered.

**Two layers, and only the tokens are mocked.** The canonical desk trades the real pair and names
`MapOracle`, which has one updater. The demo desk trades tokens anyone can mint and names
`DemoMapOracle`, which anyone can write, so a visitor can operate the design's one trusted input
instead of reading a sentence about it. Both price against the same live book.

That split is the trust argument stated as a deployment. The map can only ever *add* a lean, one
below a desk's own floor does nothing, and a stale one is ignored — so the worst a broken keeper can
do is take a lean away. But a desk quoting inside L1 is a desk offering a better price than L1, and
an oracle anyone can write is an oracle anyone can be paid out of. So no desk holding real inventory
points at the open one, and the console says which oracle each desk names.

## Status

The quote, the program encoder, the desk account and the console are built and tested against
1inch's own Aqua and the SwapVM router deployed on 999. The HyperCore reader has been run against a
live node. Deployment to mainnet, the subgraph and the CoreWriter cover leg are next; the numbers
arrive when the replay runs on a real tape.

**The death metric, on the deployed router.** Against a fork of 999 carrying the real Aqua and the
real SwapVM, two swaps of 1 000 quote units into the same desk with the book moved between them:
`amountOut` went from 1 242 236 at a 799 500 / 799 510 book to 1 226 899 at 810 000 / 810 010. Both
settled through `swap()` and emitted `Fill` with the four L1 words in it. Reproduce with
`./script/localnet.sh` — it prints the two commands.

## Build

```
yarn install --frozen-lockfile --ignore-scripts
forge build
forge test
./script/localnet.sh          # fork 999, deploy, ship, swap, against the real router
python3 -m http.server 8000   # then http://localhost:8000/app/
```

- Foundry `nightly`. `@1inch/aqua` and `@1inch/swap-vm` resolve from GitHub at **`v1.0.0` and
  `v1.0.2`, which is what is deployed on 999** — not at `main`, whose `quote` and `swap` take
  different arguments. `results/999_router_abi.md` has the selectors and how the difference
  surfaced. `@1inch/solidity-utils` is held at 6.9.10 through `resolutions`, because Aqua's 6.9.7
  is missing `TransientLockUnsafe.sol`.
- A SwapVM opcode is **a position in the router's own instruction table**, so `XYCSwap` is 17,
  `Salt` 20 and `Extruction` 32. `test_opcodes_matchTheRoutersOwnTable` derives all three from
  `AquaOpcodes._opcodes()` rather than trusting the constants.
- HyperEVM mainnet is chain 999 (gas 0.1 gwei), testnet 998. `eth_getLogs` caps at 1000 blocks.
- **Blocks come in two sizes and the small one is the default**: 118 of 120 sampled blocks capped
  at 3 000 000 gas, two at 30 000 000. Code deposit is 200 gas a byte, so contract size is a
  deployment constraint here — `optimizer_runs` is 200 so that `DeskAccount` fits, and the factory
  takes its implementation as an argument rather than building it. `results/999_deploy_budget.md`
  has every contract's deploy gas and what the setting costs a taker.
- **The precompiles ignore the block tag.** A read pinned 200 000 blocks back returns the current
  book, so there is no archive read of L1 state: `BookCache` is not a fallback, it is the only
  history there is, and a page must take its whole snapshot in one call.
- **The HyperCore precompiles carry no bytecode**, so a forge fork cannot call them and much of
  the suite is skipped until the piece it covers exists. Tests etch `test/mocks/HyperCoreMock.sol`
  at `0x0806` / `0x0807` / `0x0809` / `0x080e` instead. What only a node can answer is measured on
  998 by `./script/probe998.sh`, which needs an RPC URL and no funded key:
  `results/998_precompiles.md` has the numbers and the reasoning they support.
- A SwapVM instruction is `[opcode][uint8 length][args]`, so **one instruction carries at most
  255 bytes** and `Extruction` spends 20 of them on its target. `abi.encode(DeskParams)` is 416 and
  does not build; the packed encoding in `src/libs/DeskParams.sol` is 138 and is exact — `decode`
  rejects any other length rather than reading a short buffer as a desk with a zero inventory band.
- The replay that draws the two lines is `forge test --match-contract Oct10Replay -vv`; it writes
  `results/oct10_replay.csv`, whose columns are documented in `results/oct10_replay.schema.md`.
  The committed CSV is a **stub run** off `tape/oct10_btc_1m.stub.json`: 123 minutes whose spot is
  real Coinbase 1m data from the 2025-10-10 cascade, whose book and forced flow are a synthetic
  overlay, and whose quote columns are the contract itself answering. Its inventory and PnL
  columns are placeholders. The file next to it, `oct10_replay.source`, says which tape produced
  it. The tape runs 60 minutes past its own last fill so every markout horizon exists.
- Three claims, three tests, and they are different questions.
  `testFuzz_noRoundTripEverProfits` asks whether the quote can ever be arbitraged against the book
  it read, which is the claim that has to hold in every block.
  `test_deathMetric_amountOutMovesWithBook` asks whether a swap responds to the regime at all — a
  program can be perfectly inarbitrable and still be a constant product that ignores L1.
  `test_gate_absorbedEdgeBeatsControl` asks whether the session's absorbed notional actually
  reverted in the desk's favour by a multiple of the control's; a desk can pass the first two and
  still draw two flat lines. When that last one fails, the taker model is the suspect before the
  quote is.

## Prior art

- Milionis, Moallemi, Roughgarden, Zhang, arXiv:2208.06046, *Automated Market Making and
  Loss-Versus-Rebalancing* — the loss this desk is built to not have.
- Milionis, Moallemi, Roughgarden, arXiv:2305.14604, *Automated Market Making and Arbitrage Profits
  in the Presence of Fees* — fees scale the loss down; they do not remove the gap that causes it.
- P1, arXiv:2607.27070 — no early warning exists; this is a nowcast, not a forecast.
- P2, arXiv:2608.03616 — the venue backstop absorbed most of the cascade; this is public absorber
  capacity.
- Chitra, arXiv:2512.01112 — auto-deleveraging is what happens when absorbers run out.
- Bouchaud, arXiv:1412.0141 — mechanical impact decays; the markout clock.
- 1inch Aqua and SwapVM, HumidiFi, HLP, Ballast, MEV-X: cited in the design notes to come.
