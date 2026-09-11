# The desk account, the cover leg, and the operator

`DeskAccount`, `cover()`, the HyperCore margin path run end to end on chain 999 with its hashes, the scales that fail silently, and the automation key that can call `cover()` and nothing else — with what the live wallet refuses.

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

