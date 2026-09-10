# coldcascade

**When the market moves, bots charge AMMs for still using the old price. This maker reads the book
before it accepts the trade.**

A maker program on 1inch Aqua whose quote is computed from Hyperliquid's own order book inside the
call that settles the swap.

That is the problem it is built against. An automated market maker is arbitraged for the distance
between its price and the reference venue's, because its price was set before the trade that takes
it. The arbitrageur's profit is the LP's loss, it has a name — **loss-versus-rebalancing** — and
fees are what an LP has to cover it with. Fees shrink it and faster blocks shrink it, but nothing
in the shape of an AMM takes it to zero, because the gap between quoting and being taken is where
the whole construction lives.

A maker that reads the reference book in the same call closes that gap against that book. This one
reads it and then clamps itself to what crossing L1 would have paid, so a round trip that takes the
desk's price and closes it at the touch the quote just read comes back negative in the quiet by the
desk's own band, and exactly zero while it is leaning. That is the channel this attacks: extraction
against a price set before the trade, bounded in the call that settles it.

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
screen for whoever is being forced out, and the round trip against the book it read is still not
positive. That half pays twice a year. The half above is true in every block.

## The bound, against the book the quote read

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

`test_lvr_theControlIsArbitrableAfterAMove_theDeskIsNot` is that bound in one test. Two
makers on 1inch's router, same pair, same inventory, both priced at the book they were shipped at.
The book then moves 12%, which is the 10 October 2025 move. The control is a constant product and
has not heard about it, so an arbitrageur now takes **1 352 bps** out of it in a single round trip.
The desk carries *the same constant product* — `XYCSwap` runs first in its own program and its
curve wants to pay that same stale price — and the bound cuts 794 715 284 units of quote back to
700 010 000, which is L1's own offer to the last unit. **Zero, not negative:** the desk is never a
better price than crossing L1, and never worse than useless.

**Where the desk still loses.** The reference price moves after a fill, which is inventory risk —
what the markout measures and what the cover leg is for. It inherits HyperCore's book, so if that
book is wrong against the rest of the world the desk is wrong with it. And a taker who is right
about the *next* move needs no instantaneous round trip to be right: the bound is against the book
in the call, on one instrument, at one instant.

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
taker cost. A swap against a contract maker costs 98 962 gas and one against an EOA maker 98 989:
the contract is the cheaper of the two, because there is no callback in the bill.

**Cover is a second transaction, sent by the owner or by an operator the owner names in
`armHedge`.** `DeskAccount.cover()` writes an IOC to CoreWriter from the desk's own margin account
— 81 641 gas, paid by the desk; a taker pays none of it. `test_cover_costsTheDeskNotTheTaker` fills
the same desk twice from one snapshot, disarmed and then armed, and the taker's gas is the same to
the unit.

CoreWriter *queues*: HyperCore executes the action some seconds later, and can reject it or fill it
partially without failing the EVM transaction that carried it. So `HedgeSent` records an order
written, and every fill below was read back off HyperCore rather than off a receipt.

**The desk remembers nothing about what it has hedged.** Both legs are read in the same call: the
spot side from `balanceOf(base)` against the square level the owner declared when funding the
desk, the perp side from `0x0800`, which is HyperCore's own record of what this account holds.
What is uncovered is their sum, and the order is that sum. It is the same move the quote makes
when it prices against the book it read in that call rather than a stored one.

The obvious alternative is a counter the desk advances each time it sends, and it does not work.
That counter is a belief about what HyperCore did, held by a contract that cannot see a fill — and
**HyperCore drops an order it does not like without failing the EVM transaction that carried it**,
so the belief walks away from the truth silently and compounds, with no call that would notice.
Reading the position does not reconcile that error; it deletes the state that could hold one. A
dropped order leaves `0x0800` unchanged, so the next cover sizes itself against the same gap and
sends again. Stale state trusted without checking is the failure this desk exists to price
against, and a hedge built on one would be the same failure wearing our name.

Two properties fall out rather than being written. The delta nets, so a desk that bought and sold
back covers once and a desk whose hedge already matches its inventory sends nothing. And `close()`
leaves the perp position standing — balance and square level both go to zero, so the whole
uncovered amount is the hedge itself and the next cover unwinds it.

`armHedge` carries the whole authorisation in one signature — armed, a ceiling per call, an
operator, and how far through the book a cover may reach. Three exchange rules are enforced before
an order goes out, for the same reason the counter is gone: sizes are floored onto the asset's
`szDecimals` grid, an order under $10 is not sent, and the limit price is built in raw precompile
units and truncated to five significant figures so it cannot be rejected for its shape. A cover
that hits one of those emits `HedgeSkipped` and sends nothing, and because there is no counter to
advance, the exposure it declined to cover is simply still there on the next call. `szDecimals` is
read from `0x080a` each time rather than configured, because it is the exchange's property and not
the maker's.

The desk's HyperCore account is its own, and it was never signed for. That is not obvious and the
two published sources disagree about it, so it was measured on chain 999 rather than argued:
Hyperliquid's docs say the 1 USDC activation fee is charged on *"the first transaction which has
the new account as destination address"*; Circle's say it is *"earmarked … and charged on the
user's first outbound action"*, and that until then the account *"cannot perform CoreWriter
actions"* — which for a contract is a dead end, because a contract's only outbound action **is** a
CoreWriter action. A transfer of 2 USDC to a fresh contract address, followed by a
`usdClassTransfer` and a one-lot IOC sent from that contract, settles it: the account was created
by the transfer, the fee was charged to the sender on the way in, both actions were executed, and
the fill came back with the `cloid` the contract had put on it.

**The path, run end to end on mainnet — by hand, one transaction at a time.** A desk at
[`0xB4ad3Fc0702145fB7a1DE72576968f9A30987a7f`](https://hyperevmscan.io/address/0xB4ad3Fc0702145fB7a1DE72576968f9A30987a7f)
was opened with 2 000 UBTC-raw and 16 USDT0, given a HyperCore margin account by a transfer, armed,
and then taken against. Every step's effect was read off HyperCore rather than off its receipt.

| | | |
|---|---|---|
| funded | 3 USDC in, landing in **spot** — 4 debited, 1 of it the protocol's activation fee | — |
| margined | `marginTransfer(3000000, true)` moved it to the perp balance | [`0xb330064a…d150`](https://hyperevmscan.io/tx/0xb330064a6ee423b04989231c039539b411d2ce2ce7dc9ca5b3499caea68fd150) |
| armed | `armHedge(true, $100, no operator, 30 bps)` | [`0xafe94d38…93f4`](https://hyperevmscan.io/tx/0xafe94d38f3696b6fbed7288d783860a396365dab26a8ba71191f0ec6f2a693f4) |
| taken | a taker sold 17 000 UBTC-raw and the desk paid 13.4790 USDT0 — **20.0 bps under the L1 bid**, which is its `quietBps` | [`0x831e2232…b431`](https://hyperevmscan.io/tx/0x831e22322346252ef6eeb618f59ef9f1a8e36de9d0e92b0fe3df15aca47ab431) |
| covered | the owner sent `cover()`, writing an IOC: `sz` 17 000, `limitPx` $79 274, `cloid` 1 | [`0x15d68c54…9b4f`](https://hyperevmscan.io/tx/0x15d68c542957371a2e84742a5af3ca9021788aebb68956cb721383b7e76d9b4f) |

The order and the fill are two observations, and the second was checked on HyperCore rather than
inferred from the first — a dropped order leaves the same EVM receipt behind. HyperCore executed
it: `Open Short`, 0.00017 BTC at $79 513, crossed, and the fill came back carrying **`cloid
0x…0001`** — the same number as the `coverId` in the desk's own `HedgeSent` log, which is what
makes an order written on HyperEVM traceable to the fill it caused on Hyperliquid's L1.

Then the desk read `coverPreview()` as square again, and **nothing wrote that down**: 19 000 of base
against a declared square level of 2 000 is +17 000, the perp position at `0x0800` is −17 lots, and
the two cancel. `squareBase` is still the 2 000 the owner funded it with.

**Getting the collateral back out is the other half of that, and it is exercised too.** A margin
account a contract can fund and trade from is worth nothing if the exit is a diagram, so the whole
path was run on 999 with $2 and the effect checked on HyperCore after each leg — never against the
EVM receipt, which succeeds either way. Three actions, because there is no action that moves USDC
out of a perp balance in one step:

| # | action | what it did | tx |
|---|---|---|---|
| 1 | limit order, IOC | closed the short, `0x0800` → `szi 0` | [`0x68af344c…98e1`](https://hyperevmscan.io/tx/0x68af344c48bfebe7d2cab7733ad679753e8ff520efadb579e6c54b4479ec98e1) |
| 2 | `usdClassTransfer(980150, false)` | perps → spot, `withdrawable` → `0.0` | [`0x93d8a100…88be`](https://hyperevmscan.io/tx/0x93d8a100796e831dfefd46209336f527497f7c276d8407e5c594f54a25a488be) |
| 3 | `spotSend(dest, 0, 198015000)` | 1.98015 USDC out, `fee 0.0` in the destination's ledger | [`0x9071ae38…e295`](https://hyperevmscan.io/tx/0x9071ae3845fc168b588ada16888e0c8ce6cd3600c5043138c9955395e34de295) |

Going in was two actions the same way: [`0x2c912656…d283`](https://hyperevmscan.io/tx/0x2c9126567bb4ac96bf02c2c2a389da4e19790df531257b2cbf3dfdb57f41d283)
moved the deposit to the perp balance and [`0x638d295d…ec02`](https://hyperevmscan.io/tx/0x638d295d9ec7e47fdf0d8c2f1eec86cf510083ccec0b41e0debfeda44693ec02)
opened the short. 2.00 USDC in, 1.98015 out: two taker fees of 0.010049 and 0.00994 of adverse
mark on an $11.17 position, which sum to 0.01999 against the 0.01985 observed — the 0.00014 gap is
rounding in the exchange's own figures. Each action cost between 53 947 and 57 267 gas.

Two scales are worth writing down because getting one wrong is silent and credible: `0x0801`
reports spot in **8** decimals while `0x0803` and `0x080f` report perps in **6**, and action 7's
`ntl` is `1e6` while the order fields are `1e8`.

What the split costs: the contract no longer knows whether a fill was on the absorbing side, so
*when* to cover is the operator's decision under the owner's ceiling, not a rule in the code. The
contract still takes no view on the sign — long base sells the perp, short base buys it.

### The operator is a key that can only do this

`armHedge`'s third argument is an address, and while it is zero the loop has a person in it: every
cover above was sent by the owner, by hand. A second desk at
[`0xa09765E0…c144`](https://hyperevmscan.io/address/0xa09765E0bBC38E1Ae37f1EB9f2D75b4cEd4dc144)
names one instead — a Privy server wallet at
[`0xf33c1145…7da3`](https://hyperevmscan.io/address/0xf33c11453144F9a44406766602885Cd353497da3)
whose entire authority, on chain and off it, is `cover()` on that desk.

**Two controls, and neither depends on the other being right.** On chain the account decides what
the key can *reach*: `cover` transfers nothing, and `withdraw`, `close`, `marginTransfer`,
`marginHome` and `armHedge` are all `onlyOwner`, so the ceiling, the slippage room and the identity
of the operator are the owner's signature and the operator cannot rewrite any of them. Off chain
the policy decides what the key can *express*: `keeper/hedge-policy.json` allows
`eth_sendTransaction` only where the chain is 999, the recipient is that desk, the value is zero and
the calldata decodes to `cover()`; denies outright anything carrying value; and denies whatever no
rule allows. The wallet holds HYPE for its own gas and there is no transaction it can sign that
sends any of it anywhere.

**That the allowlist names a call and not a ceiling is what makes it hold across both domains.** A
HyperEVM address is also a HyperCore account, and `CoreWriter` at `0x3333…3333` forwards actions to
the exchange on behalf of whoever calls it — inside an ordinary `eth_sendTransaction` whose `value`
is zero, so a rule written as a spending limit does not see it. This policy names the destination and
the decoded function, so the door is closed by the same clause that closes every other one, and
`hedge-check.mjs` asks it directly rather than inferring it. The operator has also never held a
HyperCore account: no spot balance, no margin, an empty ledger. The desk's collateral sits under the
*desk's* address, and `CoreWriter` acts for its caller, so an operator that could reach it would be
spending its own nothing.

Both halves are owned by the same P-256 key, and that is the second lock rather than a detail: a
Privy policy is not enforced at all on a wallet whose `owner_id` is null, and a policy whose own
`owner_id` is null can be rewritten by anything holding the app secret. An owned wallet under an
unowned policy is a lock with its key beside it.

`node script/hedge-check.mjs` is where that stops being a description. It asks the live wallet for
each of these and reports what came back:

| asked of the live wallet | answer |
|---|---|
| `cover()` on the desk, chain 999, value 0 | **allowed** — and stopped at the node, because the check sends a nonce far ahead of the account |
| the same `cover()` on the hedged desk | `policy_violation` |
| `close()`, which returns the desk's inventory to its owner | `policy_violation` |
| `armHedge()`, which is the operator rewriting its own ceiling | `policy_violation` |
| `transfer()` of the desk's UBTC | `policy_violation` |
| `spotSend` through `CoreWriter`, which moves a HyperCore balance | `policy_violation` |
| `personal_sign` | `policy_violation` |
| the same `cover()` on Ethereum mainnet | `policy_violation` |
| `cover()` with 1 wei attached | `policy_violation` |
| `cover()` with no owner signature | `401` — the app secret alone signs nothing |
| a partial `{to, data}` aimed anywhere else | `policy_violation` — an unpopulated request is still read on the fields it does carry |
| does the wallet have an owner? the policy? | both, or the run fails |

`close()` and `armHedge()` differ from the allowed call in four bytes of calldata and nothing else —
same desk, same chain, same zero value — which is the sharp form of the question, because a policy
that only reads the envelope would pass them.

**One measurement is worth keeping out of the check's way.** A request Privy still has to populate
gets its gas estimated first, so calldata the desk would revert on comes back as
`transaction_broadcast_failure` *before the policy has said anything*, which reads exactly like a
policy that allowed it. Asking a policy question with reverting calldata gets an answer from the
node instead. Every case above is either fully populated or uses calldata that does not revert.

`script/cover.mjs` is the sender: it reads `coverPreview()` — the same `HedgeOrder.plan` the
transaction would run — and sends nothing when the desk is square, which on a cadence is most
minutes. **The decision is a threshold on inventory, not a view about the market**: spot balance
against the declared square level, plus the perp position `0x0800` reports, and the order is their
sum. It reads no history and keeps none — *when* to cover is left to the operator on purpose, and
today the operator's answer is "whenever the sum is not zero". It builds the whole transaction itself, because a policy is evaluated against the request
as sent and a request that omits `chain_id` cannot be judged on `chain_id`.

| | | |
|---|---|---|
| opened | a second desk, 1 000 UBTC-raw and 2 USDT0, so the hedged desk's live position is not the test subject | [`0x6ae81751…f7f8`](https://hyperevmscan.io/tx/0x6ae817512ba1d5a36b1552e36f30b74f2a0bc12b5f79a2b113490bd4bb20f7f8) |
| armed | `armHedge(true, $20, 0xf33c1145…7da3, 30 bps)` — the owner's signature, naming the key | [`0x15d44e34…603e`](https://hyperevmscan.io/tx/0x15d44e3483a0b038f98f358556b79785fd8b5107bb72fa643b13e9e8ccc9603e) |
| absorbed | a taker sold **15 000 UBTC-raw**; the desk holds 16 000 against a square level of 1 000 | [`0x17f1ab16…3799`](https://hyperevmscan.io/tx/0x17f1ab1670e3175cf738e16efc7156e341253f13f9ec054a55de87c0150b3799) |
| **covered, unattended** | five minutes later the cadence read `coverPreview()`, decided *sell 15 000 base, $11.81 at mark*, and sent `cover()`. 146 793 gas, out of the operator's own HYPE | [`0x932aeaa5…e6b7`](https://hyperevmscan.io/tx/0x932aeaa549b09de47a819287f6cbf77a327046164a38cbee5c228ed26207e6b7) |

**Nobody signed the last row.** The owner armed the desk and went away, the fill arrived from a
taker, and the order came out of a cadence. What HyperCore did with it was read ten seconds later
off `0x0800` and the exchange's own endpoint, not off the receipt:

```
szi           -0.00015 BTC          dir "Open Short", crossed, fee 0.005314 USDC
entryPx       78 730.0              positionValue 11.81085
accountValue  2.993336              liquidationPx 97 476  (+24% on the mark)
cloid         0x…0003
```

**`cloid 3` is the claim in one number.** It is the desk's `coverCount`, it is the `coverId` indexed
on both `HedgeIntent` and `HedgeSent` in that transaction, and the transaction was signed by a
wallet that can call `cover()` on one address and is refused everything else. `HedgeSent` recorded a
`limitPx` of **78 493** — the bid less its 30 bps of room — and the fill came back at 78 730, at the
book, above the backstop it was given.

The fill in the third row is there to create the exposure, and its price is the desk's own curve on
the 1 000 raw it was shipped with. The bound is measured in `0xfaf1b6c6…dab20`, above.

Two live shorts now stand on chain 999, from two desks: one the owner sent by hand on 7 September,
one an automation key sent on 8 September under a policy that permits nothing else. The pair is the
argument about who is trusted with what, in the only form that can be checked.

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

## The console

One URL. The Floor leads with the round trip above — recomputed off the live book every two
seconds, and the reason the quiet screen is the evidence rather than the absence of it. Under it:
Hyperliquid's BTC book as `CoreQuote` reads it, the desks quoting against it, a map button that
puts a desk into a lean so the other half is on the screen on demand, and a Take button that swaps
through the official router.

**Taking a desk needs an email address and nothing else.** Type one, receive a six-digit code, and a
Privy embedded wallet appears on the chain the page is reading — then mint the demo token, approve
the router, swap. Three transactions, no extension, no seed phrase, no funding step. A wallet minted
this way holds no HYPE and Privy's gas sponsorship does not cover chain 999, so `api/faucet.mjs`
drips 0.002 HYPE once per Privy user — keyed on the identity in the access token rather than on the
address, because an address is free to mint and a faucet keyed on one is empty within the hour. It
signs with a Privy server wallet held under a policy that allows `eth_sendTransaction` on chain 999
up to that amount, denies `CoreWriter` outright, and permits nothing else — so the worst case if
every line of that file is wrong is one drip, on either side of the chain. The policy is `keeper/policy.json`, as Privy returns it, and `test/api/faucet.test.mjs`
asserts what the endpoint refuses.

**Three things have to be true before such a policy means anything, and none is documented.** All
were measured on the live wallet rather than assumed, and each one silently turns the policy into
decoration:

1. **A policy is not enforced until the wallet has an owner.** With `owner_id` null, a rule denying
   *every* method was attached to this wallet and a send still reached the node. The policy needs
   one too, for a different reason: it is enforced without one, but the app secret alone can rewrite
   its rules.
2. **A partial transaction bypasses every condition.** Privy evaluates a policy against the request
   as sent, before it populates anything, so a condition naming a field the request omits resolves
   to nothing and passes. `{to, value}` — the shape Privy's own quickstart shows — leaves `chain_id`
   unresolvable and the chain restriction is a no-op. A rule denying the exact destination address
   did not stop a send until the transaction carried all of its fields, which is why `api/faucet.mjs`
   builds nonce, gas, fees and chain id itself instead of letting Privy fill them in.
3. **A ceiling on `value` is a ceiling in one execution domain, and this wallet has assets in two.**
   A HyperEVM address is also a HyperCore account with its own balances, and `CoreWriter` at
   `0x3333…3333` forwards actions to the exchange for whoever calls it — an `eth_sendTransaction`
   carrying zero value, which every rule written against `value` admits while HyperCore moves the
   money. So the policy denies `to == 0x3333…3333` outright. `to` is the only field that can say it:
   `ethereum_transaction` exposes no `data` and the schema has no `neq`, so *"anywhere but the
   system contract"* is unwriteable and the door has to be named. That DENY is what makes the
   ceiling a bound on what this wallet **holds**, and not only on what it can send on the EVM.

**There are two policy-held wallets here, and the second is the more interesting one.** The faucet
gives a visitor gas; the hedge operator holds `hedgeOperator` on a desk and may call `cover()` and
nothing else, on chain and off it — that is *The operator is a key that can only do this*, above.
The same two findings apply to it and were re-measured on it rather than assumed to have carried
over, and it added a third that this one now has as well: **the policy needs an owner, not just the
wallet.** A policy whose own `owner_id` is null is enforced, but anything holding the app secret can
rewrite its rules — an owned wallet under an unowned policy is a lock with its key hanging beside
it. Both wallets and both policies are owned; `script/faucet-owner.sh` does both in one run and
refuses to rotate a key that is already in use.

With both in place the two secrets are independent: the app secret authenticates the app, the owner
key authorizes the request, and an unsigned send is refused with a 401. `node script/faucet-check.mjs`
re-runs all six cases — the drip, another chain, over the cap, another method, unsigned, and the
`CoreWriter` call — against the live wallet and reports which the policy let through.

**What building on that policy engine actually cost, with the requests and the responses, is
[`FEEDBACK-PRIVY.md`](FEEDBACK-PRIVY.md).** Six findings, with the requests and the responses. The
one worth the sponsor's time is the sixth, because it is not specific to this chain: a policy whose
conditions are `value` and `chain_id` reads as a spending limit and is one only where the chain's own
gas token is the only thing the key controls. Any system contract that moves assets held under the
same address in another domain — an exchange, a staking module, a bridge — is outside what those two
fields can see, and the schema offers no `neq` with which to exclude a set of them. A policy written
as an allowlist of calls survives that; one written as a ceiling does not, and nothing in the
condition reference tells a reader which shape they are choosing.

The read path has no third party in it. `app/src/abi.js` is a hand-written codec so that nothing
sits between a browser and the calldata going to 1inch's router, and Privy's SDK is vendored rather
than pulled from a CDN and imported only when a visitor asks for a wallet — the book, the desks and
the round trip above are this repository's own code against a node.

It is live before the contracts are: where nothing is deployed, `CorePrecompiles`, `CoreQuote` and
`FloorLens` are planted at throwaway addresses by an `eth_call` state override and the canonical
parameters are priced against the real book. The bytecode is what `forge build` produced and the
node running it is a real one — `./script/probe999.sh` is the same three calls from a shell, and
`results/999_live_quote.md` is what they answered.

**Two layers, and only the demo one is mocked.** The canonical desk trades the real pair — UBTC
`0x9FDBdA0A…3463` against USD₮0 `0xB8CE59FC…5ebb` on 999 — and names `MapOracle`, which has one
updater. The demo desk trades tokens anyone can mint and names `DemoMapOracle`, which anyone can
write, so a visitor can operate the design's one trusted input instead of reading a sentence about
it — and the flow on it is ours: `script/demo-cadence.sh` takes it on a schedule, so that desk's
history is the quote path holding across a week of moving book, not demand anyone brought. Both
price against the same live book.

That split is the trust argument stated as a deployment. The map can only ever *add* a lean, one
below a desk's own floor does nothing, and a stale one is ignored — so the worst a broken keeper can
do is take a lean away. But a desk quoting inside L1 is a desk offering a better price than L1, and
an oracle anyone can write is an oracle anyone can be paid out of. So no desk holding real inventory
points at the open one, and the console says which oracle each desk names.

## Status

The quote, the program encoder, the desk account and the console are built and tested against
1inch's own Aqua and the SwapVM router deployed on 999. The HyperCore reader has been run against a
live node, and the round trip above is the live book answering today. **It is deployed.** Fifteen
contracts on chain 999 — twelve on 6 September and three more with the hedge leg on the 7th — four
desks shipped and open, and the canonical desk holds real UBTC and USD₮0. The taker path is live end to end from an email address, and the CoreWriter
cover leg has been sent from a desk and filled on HyperCore. A desk can hand that trigger to an
automation key that may call `cover()` and nothing else — on chain and under a policy — and one on
999 did: it absorbed a fill, and five minutes later a cadence covered it with no signature from
anyone. The desk's own record is indexed off Substreams and the keeper posts markouts back to the
chain, described below.

Every fill on chain so far is one we sent; there is no external flow yet.

**The first swap through the router on mainnet.**
[`0x9407579f…537c`](https://hyperevmscan.io/tx/0x9407579f28988f85c0655637d5437476bf5371b59de63602b13936b10993537c),
block 45 193 088, 2026-09-06T15:28:32Z, 194 007 gas. 1 000 demo quote units into the demo desk
through `swap()` on `0x111111338c5091E8440b67B168bAe16a668AC0De`, and `DeskHooks` emitted `Fill`
with the book it was filled against in it: bid 796 140, ask 796 150, mark 796 060, oracle 796 300,
map empty. The strategy hash in the log is the one `quote()` returned before it was sent.

**That fill was priced by the curve, not by the bound, and the arithmetic says so.** 1 000 units is
0.6% of the demo desk's quote reserve, and constant product alone on its 2 base / 160 000 quote
gives `2e8 · 1e9 / (1.6e11 + 1e9)` = **1 242 236**, which is the fill to the last unit. The bound
only ever cuts a quote *down* to L1's crossing price; here `XYCSwap` was already asking more than
L1 plus the band, so there was nothing to cut. Read it as proof that the program dispatches and
settles on 1inch's deployed router, not as a demonstration of the clamp.

**The clamp is this one.**
[`0xfaf1b6c6…ab20`](https://hyperevmscan.io/tx/0xfaf1b6c68aeae9eaed9ff49acc54d0ac7081f1537b602f5609679238c22dab20),
block 45 195 770, 194 108 gas — 0.01 base sold *to* the desk, where the bound has something to cut,
because the desk's own curve wanted to pay far more than L1 for base it was short of:

| | |
|---|---|
| the desk paid | 795 396 020 quote for 1 000 000 base = **79 539.60** per unit |
| L1's bid, in the same call | 796 990 raw = **79 699.00** |
| | **−20.00 bps**, which is `quietBps` to the basis point |

The pool ratio at that moment was 81 003, so `XYCSwap` alone would have paid **+163.6 bps over L1's
bid** — free money for whoever took it. That is the same quantity the artifact reports as
`poolDevBps` 160.8, measured against the oracle instead of the bid; the ~2.8 bps between them is
where the book sat relative to oracle in that block. Two denominators, one pool. The bound cut it to
L1's own bid less the band and stopped there.
That is the whole mechanism in one transaction: against the book read in that call, the desk is
never a better price than crossing L1.

**And the taker was a wallet that cost nothing to create.** `0x9D597dDf…6E85` is a Privy embedded
wallet made from an email address minutes earlier — no extension, no seed phrase, no funding step.
It was given 0.002 HYPE by `api/faucet.mjs` and spent 0.000073 of it on the three transactions.

| | |
|---|---|
| Canonical desk | [`0xCbDe7c24…A197`](https://hyperevmscan.io/address/0xCbDe7c24B5963d01eC64b08BB4e2e8BA1707A197) — real inventory |
| Demo desk | [`0xC76137e4…15B2`](https://hyperevmscan.io/address/0xC76137e49BF4D323190a4Ee694b47D5a2Ac515B2) — mintable tokens, take it for nothing |
| `CoreQuote` | [`0xE4DE197A…Df2B`](https://hyperevmscan.io/address/0xE4DE197A81dEa935F72557DC5Bd4F6f1e194Df2B) |
| `DeskHooks` | [`0x84C1D720…A363`](https://hyperevmscan.io/address/0x84C1D720787F7D197dfc2890862E69c42aB0A363) |
| `DeskFactory` | [`0xd72e2293…093d`](https://hyperevmscan.io/address/0xd72e2293a37DAd1596c68a35261Eef6B8B7c093d) |

The full address book is `deployments/999.json`; the deploy itself, what it cost and the three
node-level failures it hit are in [`results/999_deploy.md`](results/999_deploy.md).

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
node test/api/faucet.test.mjs # the one server-side endpoint, and what it refuses
node script/faucet-check.mjs  # the same denials against the live wallet, so the policy is a fact
python3 -m unittest discover -s mcp/tests   # the MCP server, and the corpus it ships with
node script/hedge-check.mjs   # what the hedge operator's key is refused: every call but cover()
DRY_RUN=1 node script/cover.mjs  # what a cover would send right now, and nothing sent
./script/probe999.sh          # the live book and the desk's two prices, no key, nothing deployed
./script/localnet.sh          # fork 999, deploy, ship, swap, against the real router
./script/mainnet.sh           # every read that can fail a mainnet deploy, before it costs anything
./script/firstswap.sh         # send the four calls Swap.s.sol prints, against a deployed chain
./script/appvendor.sh         # rebuild app/vendor/privy.js and app/privy.json
python3 -m http.server 8000   # then http://localhost:8000/app/
```

- **Foundry is pinned to one build**, in CI and for every gas figure in this file:
  `nightly-975a456ef42ab506b8d343df5541a248798c5a27` (forge 1.4.4-nightly, 2025-11-14),
  installed with `foundryup --install nightly-975a456ef42ab506b8d343df5541a248798c5a27`. The
  suite asserts gas, and two forge builds do not report the same gas for the same bytecode — the
  rolling `nightly` is a different compiler on every run. `@1inch/aqua` and `@1inch/swap-vm`
  resolve from GitHub at **`v1.0.0` and
  `v1.0.2`, which is what is deployed on 999** — not at `main`, whose `quote` and `swap` take
  different arguments. `results/999_router_abi.md` has the selectors and how the difference
  surfaced. `@1inch/solidity-utils` is held at 6.9.10 through `resolutions`, because Aqua's 6.9.7
  is missing `TransientLockUnsafe.sol`.
- **That dependency graph is fragile and nothing else may share it.** A single `yarn add` at the
  root re-resolved it: it rewrote `@1inch/swap-vm`'s own dependency edges, installed a different
  swap-vm tree from cache, and `forge build` stopped finding `ProgramBuilder.sol` — a broken
  contract build caused by adding a JavaScript bundler. So the console's toolchain lives in
  `script/vendor/` with its own `package.json` and lockfile and cannot reach this one. If the
  contracts ever stop compiling right after an install, compare `node_modules/@1inch/swap-vm/test/utils/`
  against the tag: yarn will happily serve a cached tree that does not match the lockfile's hash.
- A SwapVM opcode is **a position in the router's own instruction table**, so `XYCSwap` is 17,
  `Salt` 20 and `Extruction` 32. `test_opcodes_matchTheRoutersOwnTable` derives all three from
  `AquaOpcodes._opcodes()` rather than trusting the constants.
- HyperEVM mainnet is chain 999 (gas 0.1 gwei), testnet 998. `eth_getLogs` caps at 1000 blocks.
- **Blocks come in two sizes and the small one is the default**: 118 of 120 sampled blocks capped
  at 3 000 000 gas, two at 30 000 000. Code deposit is 200 gas a byte, so contract size is a
  deployment constraint here — `optimizer_runs` is 200 so that `DeskAccount` fits, and the factory
  takes its implementation as an argument rather than building it. `results/999_deploy_budget.md`
  has every contract's deploy gas and what the setting costs a taker.
- **A swap cannot be sent by `forge script`.** `forge script` runs the body of `run()` in its own
  EVM to collect the transactions it will broadcast — including the ones inside
  `vm.startBroadcast()` — and that EVM is a fork, which cannot serve the HyperCore precompiles. A
  call to `0x080e` lands on an empty account, so `bounds()`, `quote()` and `swap()` revert with
  `PrecompileCallFailed` before a single transaction exists. `--skip-simulation` does not help: it
  skips the simulation of transactions already collected, not the execution that collects them.
  So `script/Swap.s.sol` is a `view` that reads the account's own state, encodes the calldata and
  **prints** the four `cast` commands — quote, mint, approve, swap. The node does serve the
  precompiles, so `cast` sends what forge cannot, and `./script/localnet.sh` runs exactly the
  lines the script prints, which is what keeps them true.
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
- The replay is `forge test --match-contract Oct10Replay -vv`; it writes
  `results/oct10_replay.csv`, whose 45 columns are documented in
  `results/oct10_replay.schema.md`. Four lines: the desk, a plain `XYCSwap` control, the same curve
  charging 30 bps through 1inch's own `FlatFeeIn`, and Hyperliquid's own touch, which is not a
  maker. Every maker is shipped into Aqua and every fill settles through the official router.
- **Both takers are blind, and that is the load-bearing part.** A forced seller walks a pot that is
  a function of the tape alone — the same notional in the quiet as in a cascade — into whichever
  maker quotes best, one clip at a time. An arbitrageur looks, against every maker identically, for
  the round trip that closes profitably at L1's own touch. Neither learns anything about a maker
  beyond the number that came back from `quote`: no regime word, no parameters, no address.
  `test_takers_areBlind` ships the same program into all three slots and requires the three lines
  to come out equal **to the dollar**. They do — $18,968 absorbed and $774,522 of arbitrage
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
  keeps $1,372 and takes 67.8% of the flow, at the tape's own spread $1,334 and 65.9%, at double
  $1,257 and 65.2%. A fourfold range in the one modelled quantity moves the headline by 9%, and
  moves it *against* the desk as the book widens — it pays L1's ask, which a wide book makes worse.
  The desk's arb notional is zero at every width.
- **The falsifier, and it is on the page rather than in a footnote.** `stressBps` is how far the
  perp book has to walk from oracle before the desk quotes inside L1 — the one decision the extra
  instruction makes. `test_report_theRegimeIsWhatCarriesIt` sweeps it with the map unwired: the
  desk leans on 123, 49, 24, 8 and 0 minutes and absorbs $43,173, $43,173, $37,527, $17,553 and
  **$0**. `test_falsifier_regimeOffCollapsesTheDesk` is that last rung asserted — no reachable
  threshold and no map, and the desk quotes 20 bps outside L1 for 123 minutes and takes **nothing**,
  while the same $56,898 of forced flow goes to the two makers willing to be the best price. It
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
  all — because it will never bid above L1's ask. That is the desk declining to join two AMMs that
  are bidding over the market, and it is exactly where the retired `desk >= 2 x control` gate
  broke: it fails there while the desk is $2,249 ahead of the better control on what it kept. The
  margin gate holds under both, 4.73 bps and 2.44.
  `test_report_flowFirstMovesTheShareAndNotTheClaim` runs the retired gate rather than describing
  it, so the example cannot rot into a story.
- Four claims, four tests, and they are different questions.
  `testFuzz_noRoundTripEverProfits` asks whether the quote can ever be arbitraged against the book
  it read, which is the claim that has to hold in every block.
  `test_deathMetric_amountOutMovesWithBook` asks whether a swap responds to the regime at all — a
  program can be perfectly inarbitrable and still be a constant product that ignores L1.
  `test_gate_deskIsNeverArbitraged` asks the first question again at session scale, against an
  arbitrageur that chooses its own size: 123 minutes, both directions, 640 bps of drawdown, nothing
  found. It also fails if the two AMMs are never arbitraged, because then the zero means nothing.
  `test_gate_deskKeepsMoreThanTheControls` asks whether any of it was worth doing: what the desk
  kept, net of what the arbitrageur took, against the **better** of the two controls, in basis
  points of the capital deployed. It is a signed margin and not a multiple, because a multiple has
  no denominator once the control loses money on what it absorbed — which is what a maker priced
  before the trade does in a cascade, and what both AMM lines do here.
- **The same rule as a Uniswap v4 hook, in `test/v4/`, deployed nowhere.** `test/v4/CoreQuoteHook.sol`
  wraps the deployed `CoreQuote` in a `beforeSwap` with a return delta, `test/v4/PoolManagerStub.sol`
  reproduces v4's delta accounting around it, and `test/CoreQuoteHook.t.sol` asserts that the hook
  and the Extruction agree to the unit over a fuzzed book, that the round trip against L1 still
  never profits, that the same hook without the returns-delta bit leaves the pool's curve paying
  1 352 bps after the 12% move, and that a feed-shaped reader cannot lean. The rule they share is
  `src/libs/Regime.sol:49-68` and `src/CoreQuote.sol:60-110`. What the exercise found is in
  [`FEEDBACK.md`](FEEDBACK.md).

## AI usage

AI assistance was used throughout this repository, and [`AI-USAGE.md`](AI-USAGE.md) says exactly
which models did what, on which parts, and what was done by hand instead. Every commit here was
reviewed, made and pushed by the author; the mechanism, the parameters and every transaction on
chain 999 are his.

## What this does not answer yet

**The comparator, and what it costs to make it fair.** The plain constant-product curve is the
weakest baseline there is, so an oracle-anchored maker was built beside it — the same band, the same
curve arithmetic, priced off HyperCore's oracle at its last refresh instead of off the book. On the
mainnet fills it pays **nothing**, exactly like the desk: on ordinary flow with a fast oracle there
is no difference between the two, and the $1.5k the flat curve pays is the drift of this repository's
own demo pool, not a fact about AMMs. In the cascade the same maker pays **$222** and finishes net
negative while the desk finishes ahead, and the dial is published: 60 s costs $222, five minutes
$2,606, fifteen minutes $3,528 — at which point it is indistinguishable from the naive curve. What
saves an oracle maker in a cascade is the deviation threshold rather than the heartbeat, because a
cascade trips the threshold by itself. The argument does not turn on which control you pick:
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

## Prior art

- Milionis, Moallemi, Roughgarden, Zhang, arXiv:2208.06046, *Automated Market Making and
  Loss-Versus-Rebalancing* — the formal definition of the loss, measured against a continuously
  rebalanced portfolio at the external price. This desk attacks one channel of it: extraction
  against a price set before the trade.
- Milionis, Moallemi, Roughgarden, arXiv:2305.14604, *Automated Market Making and Arbitrage Profits
  in the Presence of Fees* — fees scale the loss down; they do not remove the gap that causes it.
- P1, arXiv:2607.27070 — no early warning exists; this is a nowcast, not a forecast.
- P2, arXiv:2608.03616 — the venue backstop absorbed most of the cascade; this is public absorber
  capacity.
- Chitra, arXiv:2512.01112 — auto-deleveraging is what happens when absorbers run out.
- Bouchaud, arXiv:1412.0141 — mechanical impact decays; the markout clock.
- 1inch Aqua and SwapVM, HumidiFi, HLP, Ballast, MEV-X: cited in the design notes to come.
