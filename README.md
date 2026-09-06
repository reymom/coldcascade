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
through the official router.

**Taking a desk needs an email address and nothing else.** Type one, receive a six-digit code, and a
Privy embedded wallet appears on the chain the page is reading — then mint the demo token, approve
the router, swap. Three transactions, no extension, no seed phrase, no funding step. A wallet minted
this way holds no HYPE and Privy's gas sponsorship does not cover chain 999, so `api/faucet.mjs`
drips 0.002 HYPE once per Privy user — keyed on the identity in the access token rather than on the
address, because an address is free to mint and a faucet keyed on one is empty within the hour. It
signs with a Privy server wallet held under a policy that allows `eth_sendTransaction` on chain 999
up to that amount and nothing else, so the worst case if every line of that file is wrong is one
drip. The policy is `keeper/policy.json`, as Privy returns it, and `test/api/faucet.test.mjs`
asserts what the endpoint refuses.

**Two things have to be true before such a policy means anything, and neither is documented.** Both
were measured on the live wallet rather than assumed, and each one silently turns the policy into
decoration:

1. **A policy is not enforced until the wallet has an owner.** With `owner_id` null, a rule denying
   *every* method was attached to this wallet and a send still reached the node.
2. **A partial transaction bypasses every condition.** Privy evaluates a policy against the request
   as sent, before it populates anything, so a condition naming a field the request omits resolves
   to nothing and passes. `{to, value}` — the shape Privy's own quickstart shows — leaves `chain_id`
   unresolvable and the chain restriction is a no-op. A rule denying the exact destination address
   did not stop a send until the transaction carried all of its fields, which is why `api/faucet.mjs`
   builds nonce, gas, fees and chain id itself instead of letting Privy fill them in.

With both in place the two secrets are independent: the app secret authenticates the app, the owner
key authorizes the request, and an unsigned send is refused with a 401. `node script/faucet-check.mjs`
re-runs all five cases — the drip, another chain, over the cap, another method, and unsigned —
against the live wallet and reports which the policy let through.

The read path has no third party in it. `app/src/abi.js` is a hand-written codec so that nothing
sits between a browser and the calldata going to 1inch's router, and Privy's SDK is vendored rather
than pulled from a CDN and imported only when a visitor asks for a wallet — the book, the desks and
the round trip above are this repository's own code against a node.

It is live before the contracts are: where nothing is deployed, `CorePrecompiles`, `CoreQuote` and
`FloorLens` are planted at throwaway addresses by an `eth_call` state override and the canonical
parameters are priced against the real book. The bytecode is what `forge build` produced and the
node running it is a real one — `./script/probe999.sh` is the same three calls from a shell, and
`results/999_live_quote.md` is what they answered.

**Two layers, and only the tokens are mocked.** The canonical desk trades the real pair — UBTC
`0x9FDBdA0A…3463` against USD₮0 `0xB8CE59FC…5ebb` on 999 — and names `MapOracle`, which has one
updater. The demo desk trades tokens anyone can mint and names `DemoMapOracle`, which anyone can
write, so a visitor can operate the design's one trusted input instead of reading a sentence about
it. Both price against the same live book.

That split is the trust argument stated as a deployment. The map can only ever *add* a lean, one
below a desk's own floor does nothing, and a stale one is ignored — so the worst a broken keeper can
do is take a lean away. But a desk quoting inside L1 is a desk offering a better price than L1, and
an oracle anyone can write is an oracle anyone can be paid out of. So no desk holding real inventory
points at the open one, and the console says which oracle each desk names.

## Status

The quote, the program encoder, the desk account and the console are built and tested against
1inch's own Aqua and the SwapVM router deployed on 999. The HyperCore reader has been run against a
live node, and the round trip above is the live book answering today. **It is deployed.** Twelve contracts on chain 999 since 6 September, three desks shipped, and the
canonical desk holds real UBTC and USD₮0. The taker path is live end to end from an email address.
The subgraph and the CoreWriter cover leg come next; the markout numbers arrive when the replay runs
on a real tape.

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

The pool ratio at that moment was 81 003, so `XYCSwap` alone would have paid **+163 bps over L1** —
free money for whoever took it. The bound cut it to L1's own bid less the band and stopped there.
That is the whole mechanism in one transaction: the desk is never a better price than crossing L1,
so there is nothing on it to arbitrage.

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
./script/probe999.sh          # the live book and the desk's two prices, no key, nothing deployed
./script/localnet.sh          # fork 999, deploy, ship, swap, against the real router
./script/mainnet.sh           # every read that can fail a mainnet deploy, before it costs anything
./script/firstswap.sh         # send the four calls Swap.s.sol prints, against a deployed chain
./script/appvendor.sh         # rebuild app/vendor/privy.js and app/privy.json
python3 -m http.server 8000   # then http://localhost:8000/app/
```

- Foundry `nightly`. `@1inch/aqua` and `@1inch/swap-vm` resolve from GitHub at **`v1.0.0` and
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
