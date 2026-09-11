# coldcascade

**A market maker on HyperEVM that reads Hyperliquid's book inside the trade — so it can't be picked
off on a stale price, hedges its own inventory on the perp, and when a liquidation cascade tears the
book open, leans in and buys what usually only the house gets to buy.**

It is a maker program on 1inch Aqua, `XYCSwap || Extruction(CoreQuote)`, on the official SwapVM
router on chain 999. `CoreQuote` reads Hyperliquid's best bid and ask, mark and oracle through the
HyperCore precompiles *in the call that settles the swap*, and clamps the price to what crossing that
book would have paid. The desk is a contract that can send its own hedge to HyperCore, and every
fill it makes carries the book it was priced against into a log, where a Substreams package and a
keeper turn it into a record nobody else on this chain can query.

| | |
|---|---|
| **Live** | [coldcascade.vercel.app](https://coldcascade.vercel.app) — four tabs, reads chain 999 every block |
| **Chain** | HyperEVM mainnet (999), on the Aqua and `AquaSwapVMRouter` contracts 1inch has in production |
| **Suite** | `forge test`: 165 passed, 3 skipped, compiler pinned so every gas figure reproduces |
| **Event** | ETHOnline 2026, From Scratch. Every number below has the command that reproduces it beside it |

## Where to look

| if you are here for | start with | on the site |
|---|---|---|
| **1inch** — an Aqua app with a SwapVM instruction that reads an order book | [`src/CoreQuote.sol`](src/CoreQuote.sol) · [`src/libs/DeskPrograms.sol`](src/libs/DeskPrograms.sol) · the clamp on mainnet, [`0xfaf1b6c6…dab20`](https://hyperevmscan.io/tx/0xfaf1b6c68aeae9eaed9ff49acc54d0ac7081f1537b602f5609679238c22dab20) · [`test/Inarbitrable.t.sol`](test/Inarbitrable.t.sol) · [`test/fork/OfficialRouter.fork.t.sol`](test/fork/OfficialRouter.fork.t.sol) | **The Desk** |
| **Privy** — a taker from an email address or a Discord account, and a server wallet that can hedge and nothing else | [`api/faucet.mjs`](api/faucet.mjs) · [`keeper/policy.json`](keeper/policy.json) · [`keeper/hedge-policy.json`](keeper/hedge-policy.json) · [`script/hedge-check.mjs`](script/hedge-check.mjs) · the unattended cover, [`0x932aeaa5…e6b7`](https://hyperevmscan.io/tx/0x932aeaa549b09de47a819287f6cbf77a327046164a38cbee5c228ed26207e6b7) · [`FEEDBACK-PRIVY.md`](FEEDBACK-PRIVY.md) | **The Keys** |
| **The Graph** — Substreams on The Graph Market, a keeper that writes back to the chain, an MCP server | [`substreams/`](substreams/) · [`keeper/coldcascade/markouts.py`](keeper/coldcascade/markouts.py) · [`mcp/`](mcp/) and its [`SKILL.md`](mcp/SKILL.md) · [`results/markouts.json`](results/markouts.json) | **The Record** |
| the mechanism in 54 seconds, on the real 10 October 2025 tape | [`film/`](film/) | **The Cascade** |
| the measurements | [`results/`](results/) and [`docs/evidence.md`](docs/evidence.md) | — |
| what it does **not** claim | [*What this does not answer yet*](#what-this-does-not-answer-yet) | the *questions* under each tab |

## What it is

An automated market maker is arbitraged for the distance between its price and the reference
venue's, because its price was set before the trade that takes it. That loss has a name —
loss-versus-rebalancing — and fees only scale it down.

This maker sets its price *during* the trade. Three things follow, and each is on chain:

1. **It is bounded by the book it read.** `CoreQuote` reads `0x080e` (best bid and ask), `0x0806`
   (mark) and `0x0807` (oracle) inside `extruction`, and the taker receives `min(curve, bound)`: the
   desk is never a better price than crossing Hyperliquid's own touch, so a round trip that takes the
   desk and closes at that touch loses by arithmetic. On mainnet, [`0xfaf1b6c6…dab20`](https://hyperevmscan.io/tx/0xfaf1b6c68aeae9eaed9ff49acc54d0ac7081f1537b602f5609679238c22dab20)
   paid **79 539.60** against an L1 bid of **79 699.00** — −20.00 bps, its own `quietBps` to the
   basis point — while its constant-product curve wanted to pay 163.6 bps *over* L1.
   `test/Inarbitrable.t.sol` asserts it over a fuzzed book, both sides, both directions.
2. **It flips when the book breaks.** One boolean in [`src/libs/Regime.sol`](src/libs/Regime.sol):
   when mark walks `stressBps` away from oracle, or a liquidation map says forced flow is coming, the
   absorbing side moves from outside the touch to inside it — `min` becomes `max` — and the desk is
   the best bid on the screen for whoever is being forced out, still bounded by the book. The map is
   the one input taken on trust and it can only ever *add* a lean; a stale one is ignored.
3. **It hedges on the same venue.** [`DeskAccount`](src/DeskAccount.sol) is the maker: an EIP-1167
   clone that ships the strategy from itself, holds a HyperCore margin account of its own, and sends
   an IOC to the perp through `CoreWriter` when its inventory is off. `cover()` is a second
   transaction, sent by the owner or by an operator the owner names in `armHedge`, under a ceiling the
   owner signed. The operator on one desk is a Privy server wallet whose policy allows `cover()` on
   that desk and refuses everything else.

**Why the book and not the oracle.** On this chain any contract can read HyperCore's oracle in the
same call, so a maker pegged to it is not stale. It is anchored to the wrong thing: the oracle is an
index of other venues' spot, not a price anyone can execute at here, and in a cascade the two
separate. An oracle-pegged maker with this desk's own band was built as the comparator
([`src/PegQuote.sol`](src/PegQuote.sol)); on 123 minutes of the 10 October 2025 tape it pays **$222**
refreshed every minute — the fastest the tape allows, so nothing left in it is staleness — and
**$294** with a 25 bps deviation trigger. The desk pays $0, absorbs ten times the flow, and keeps
it. Most of what an oracle maker loses is being stale; what remains when it stops being stale is
where it is anchored. The first is fixed by a better oracle. The second is not.

The long form — the round trip at a live block, the 1 352 bps test, where the desk still loses —
is [`docs/mechanism.md`](docs/mechanism.md).

## On chain 999

Fifteen contracts, deployed 6–7 September; four desks shipped and open; the canonical desk holds
real UBTC and USD₮0. The address book is [`deployments/999.json`](deployments/999.json); the deploy,
its cost and the three node-level failures it hit are in [`results/999_deploy.md`](results/999_deploy.md).

| | |
|---|---|
| Canonical desk — real pair, `MapOracle` | [`0xCbDe7c24…A197`](https://hyperevmscan.io/address/0xCbDe7c24B5963d01eC64b08BB4e2e8BA1707A197) |
| Demo desk — mintable pair, `DemoMapOracle` anyone can write | [`0xC76137e4…15B2`](https://hyperevmscan.io/address/0xC76137e49BF4D323190a4Ee694b47D5a2Ac515B2) |
| Hedged desk — cover sent by the owner | [`0xB4ad3Fc0…7a7f`](https://hyperevmscan.io/address/0xB4ad3Fc0702145fB7a1DE72576968f9A30987a7f) |
| Operator desk — cover sent by a policy-held key | [`0xa09765E0…c144`](https://hyperevmscan.io/address/0xa09765E0bBC38E1Ae37f1EB9f2D75b4cEd4dc144) |
| `CoreQuote` · `DeskHooks` · `DeskFactory` | [`0xE4DE197A…Df2B`](https://hyperevmscan.io/address/0xE4DE197A81dEa935F72557DC5Bd4F6f1e194Df2B) · [`0x84C1D720…A363`](https://hyperevmscan.io/address/0x84C1D720787F7D197dfc2890862E69c42aB0A363) · [`0xd72e2293…093d`](https://hyperevmscan.io/address/0xd72e2293a37DAd1596c68a35261Eef6B8B7c093d) |
| `BookCache` — the book, written down once a minute | [`0x24496697…5533`](https://hyperevmscan.io/address/0x24496697E43dE61af09561fb414cb909C1635533) |
| `MarkoutLedger` — where the keeper writes its decisions | [`0xC938e0de…d0e9`](https://hyperevmscan.io/address/0xC938e0deD6A7a65B8f92Ca56E8688801eF0Ad0e9) |

The transactions that carry the argument, each read back off the chain rather than off its receipt:

| | what it shows | tx |
|---|---|---|
| **The clamp** | 0.01 base sold to the demo desk; the bound cut the curve's +163.6 bps to −20.00 bps against the L1 bid read in the same call | [`0xfaf1b6c6…dab20`](https://hyperevmscan.io/tx/0xfaf1b6c68aeae9eaed9ff49acc54d0ac7081f1537b602f5609679238c22dab20) |
| **The first swap through the router** | settlement on `0x111111338c5091E8440b67B168bAe16a668AC0De`; priced by the curve, not the bound | [`0x9407579f…537c`](https://hyperevmscan.io/tx/0x9407579f28988f85c0655637d5437476bf5371b59de63602b13936b10993537c) |
| **A taker from an email** | the wallet that sent the clamp was three minutes old — no extension, no seed, gas dripped by a policy-held faucet | `0x9D597dDf…6E85` |
| **Cover, by hand** | the hedged desk absorbed 17 000 UBTC-raw at −20.0 bps, and the owner's `cover()` wrote an IOC HyperCore filled: `Open Short` 0.00017 BTC at $79 513, `cloid 1` = the desk's `coverId` | [`0x831e2232…b431`](https://hyperevmscan.io/tx/0x831e22322346252ef6eeb618f59ef9f1a8e36de9d0e92b0fe3df15aca47ab431) · [`0x15d68c54…9b4f`](https://hyperevmscan.io/tx/0x15d68c542957371a2e84742a5af3ca9021788aebb68956cb721383b7e76d9b4f) |
| **Cover, unattended** | the operator desk absorbed 15 000 raw; five minutes later a cadence read `coverPreview()` and a Privy server wallet sent `cover()`. HyperCore filled −0.00015 BTC at 78 730, `cloid 3`. Nobody signed it | [`0x17f1ab16…3799`](https://hyperevmscan.io/tx/0x17f1ab1670e3175cf738e16efc7156e341253f13f9ec054a55de87c0150b3799) · [`0x932aeaa5…e6b7`](https://hyperevmscan.io/tx/0x932aeaa549b09de47a819287f6cbf77a327046164a38cbee5c228ed26207e6b7) |

Two live shorts stand on chain 999 from two desks — one the owner sent by hand, one an automation
key sent under a policy that permits nothing else. Both positions can be read on Hyperliquid's own
API; **The Keys** tab prints the two `curl` lines. CoreWriter *queues*: HyperCore executes an action
seconds later and can reject it without failing the EVM transaction, so every fill above was read
off `0x0800`, never inferred from a receipt. The whole path, the scales that fail silently and the
way the collateral gets back out are in [`docs/desk-account.md`](docs/desk-account.md); the
deployment and the clamp's arithmetic in [`docs/mainnet.md`](docs/mainnet.md).

## The evidence, and why it does not add

**The replay** — 123 minutes of the 10 October 2025 cascade, `forge test --match-contract Oct10Replay`.
Spot and taker volume are real Coinbase minute bars; the book is modelled. Five lines, every maker
shipped into Aqua, every fill settled through the official router, both takers blind
(`test_takers_areBlind` ships the same program into all four slots and gets four equal lines):

| | absorbed | edge at 60 min | paid to the arbitrageur | net |
|---|---|---|---|---|
| the desk | $36 878 | +$1 306 | **$0** | **+$1 306** |
| oracle-pegged, refreshed every minute, same band | $3 621 | +$18 | $222 | −$204 |
| plain `XYCSwap` | $5 620 | −$34 | $3 558 | −$3 592 |
| `XYCSwap` at 30 bps | $10 812 | −$315 | $2 713 | −$3 028 |
| Hyperliquid's own touch — not a maker | $57 094 | +$1 225 | $0 | — |

The oracle-pegged line's number is a function of its cadence and the cadence is published: 60 s
$222, five minutes $2 606, fifteen minutes $3 528, a 25 bps deviation trigger $294
(`test_report_theCadenceIsTheDial`). Switch the regime off and the desk absorbs $0 — the regime
decides how much it trades; the clamp decides that none of it is a profitable round trip.

**Mainnet** — the same searcher run over every fill the desks have signed, at each fill's own size,
closing at Hyperliquid's touch with no fee and infinite depth, so every toll is a floor
(`keeper/coldcascade/tolls.py`, `counterfactuals` in [`results/markouts.json`](results/markouts.json)).
The desk pays $0. So does an oracle-pegged maker refreshed every minute: on ordinary flow with a fast
oracle the two are the same maker, which is the point. The plain curve on the same reserves pays
about $1.8k, and that is the drift of this repository's own demo pool, not a fact about AMMs.

**They do not add.** The replay's markout is the markout of *uncovered* inventory; the cover leg
gives up exactly the rebound it measures. Spot bought at `P`, short opened at `H`, both marked at
`M`: `q(M − P) + q(H − M) = q(H − P)`. A hedged desk's P&L is a third measurement this repository
does not have. The full replay — the modelled book's dial, the falsifier, the four claims and the
four tests behind them — is [`docs/evidence.md`](docs/evidence.md).

## The three sponsors

**1inch.** The program is `XYCSwap || Extruction(CoreQuote)` on the Aqua registry and the
`AquaSwapVMRouter` deployed on 999 — `@1inch/aqua` at `v1.0.0` and `@1inch/swap-vm` at `v1.0.2`,
which is what is in production, not `main`. `Extruction` is the official extension point and
`IStaticExtruction.extruction` is `view`, which is exactly the hole a precompile `STATICCALL` fits;
a custom opcode would need a redeployed router, and then the desk is not on the venue that has the
liquidity. Opcodes are derived from the router's own table in a test (`XYCSwap` 17, `Salt` 20,
`Extruction` 32). The maker's parameters are packed into 138 bytes because one instruction carries at
most 255. `DeskHooks` is 1inch's `IMakerHooks`, emitting the fill and stopping, so a swap against a
contract maker costs 98 962 gas and against an EOA 98 989. Aqua custodies nothing; the desk
keeps its own inventory. Where 1inch's own words apply: a maker whose automation can act but cannot
move funds is the opposite of a rug-pull shape.

**Privy.** Two flows, two server wallets, two policies. A visitor signs in with an email address or a
Discord account, and has an embedded wallet on chain 999; `api/faucet.mjs` drips 0.002 HYPE once per Privy
user from a server wallet whose policy allows that and nothing else, and the visitor takes a desk
through the official router in three transactions. The second wallet is `hedgeOperator` on the
operator desk: its policy allows `eth_sendTransaction` only where the chain is 999, the recipient is
that desk, the value is zero and the calldata decodes to `cover()`, and denies `CoreWriter` outright.
`script/hedge-check.mjs` asks the live wallet twelve questions — `close()`, `armHedge()`, a
transfer, another desk, another chain, 1 wei, no owner signature — and prints the twelve refusals.
Three things a policy needs before it binds, none of them documented, were measured on the way and
are in [`FEEDBACK-PRIVY.md`](FEEDBACK-PRIVY.md) with the requests and responses.

**The Graph.** HyperCore's book is not HyperEVM state: the precompiles accept a block tag and return
the present, so *what the book was* fifteen minutes ago exists only if somebody wrote it into a log
while it was true. `BookCache.poke` does, once a minute, permissionlessly. [`substreams/`](substreams/)
decodes `Fill`, `Booked`, `MapUpdated` and `Markout` off HyperEVM blocks through **The Graph Market
for Substreams** (`hyperevm.substreams.pinax.network`; Subgraph Studio reports
`subgraphsSupportLevel: "none"` for this chain). The keeper joins every fill to the book 5, 15 and
60 minutes later, posts the result to `MarkoutLedger`, and reads its own decision back off the same
stream on the next pass. [`mcp/`](mcp/) serves the archive and the record over the Model Context
Protocol — eight tools, standard library only, a committed corpus so a clone answers with no
credentials, and `sync_stream` to bring it to head from Pinax with a free key. Nothing is
interpolated, absence keeps its four names, and every answer carries the `substreams run` and `cast`
commands that reproduce it. [`mcp/SKILL.md`](mcp/SKILL.md) is the manual.

## The console

[coldcascade.vercel.app](https://coldcascade.vercel.app). No framework, no build step, no CDN: the
ABI codec is hand-written so nothing sits between the browser and the calldata to 1inch's router, and
the Privy SDK is vendored and loaded only when a visitor asks for a wallet.

- **The Desk** — the book as `CoreQuote` reads it, the desks quoting against it, the live round trip,
  a button that posts a liquidation map and flips the demo desk into its second regime on chain, and
  *take it*: an email address, three transactions, a fill through the official router.
- **The Record** — every fill the desks have signed against the band, the keeper's last decisions,
  and *ask the archive*: what the book was at any instant since the series began, as a bracket.
- **The Cascade** — the 54-second film of the mechanism on the real tape, and the replay's five
  lines minute by minute.
- **The Keys** — the two live shorts, who signed each, and what the operator's wallet refuses.

Each tab ends with its *questions*. The film's source is [`film/`](film/): a Remotion composition
whose every frame is a function of `results/oct10_replay.csv`, rebuilt with `npx remotion render`.

## Repository

| | |
|---|---|
| [`src/`](src/) | `CoreQuote` (the instruction), `DeskAccount` / `DeskFactory` / `DeskHooks` (the maker), `BookCache`, `MapOracle`, `MarkoutLedger`, `PegQuote` (the comparator), `libs/` (`Regime`, `DeskParams`, `HedgeOrder`, `HyperCore`) |
| [`test/`](test/) | the suite; `Inarbitrable.t.sol`, `Oct10Replay.t.sol`, the fork test against the real router, `mocks/` etching the precompiles, `v4/` the same rule as a Uniswap hook |
| [`script/`](script/) | deploy, ship and probe scripts; the four cadences; `hedge-check.mjs`, `faucet-check.mjs`, `cover.mjs`, `status.sh` |
| [`app/`](app/) · [`api/`](api/) | the console and its one serverless endpoint, the faucet |
| [`keeper/`](keeper/) | the markout keeper, the tolls, the tape builder; the two Privy policies as Privy returns them |
| [`substreams/`](substreams/) · [`mcp/`](mcp/) | the Rust package and the `.spkg`; the MCP server and its `SKILL.md` |
| [`film/`](film/) | the mechanism film, from the replay's CSV |
| [`results/`](results/) · [`tape/`](tape/) | every measurement, with the command that produced it; the 10 October tape |
| [`deployments/`](deployments/) | the address book per chain |
| [`docs/`](docs/) | the long form: [mechanism](docs/mechanism.md) · [desk account and cover](docs/desk-account.md) · [record and MCP](docs/record.md) · [console](docs/console.md) · [mainnet](docs/mainnet.md) · [evidence](docs/evidence.md) · [building on HyperEVM](docs/hyperevm-notes.md) |

## Build and run

```
yarn install --frozen-lockfile --ignore-scripts
forge build && forge test
python3 -m unittest discover -s mcp/tests   # the MCP server and the corpus it ships with
python3 -m unittest discover -s keeper/tests
./script/probe999.sh          # the live book and the desk's two prices — no key, nothing deployed
./script/localnet.sh          # fork 999, deploy, ship, swap against the real router
node script/hedge-check.mjs   # what the hedge operator's key is refused: every call but cover()
node script/faucet-check.mjs  # the same for the faucet
DRY_RUN=1 node script/cover.mjs
python3 -m http.server 8000   # then http://localhost:8000/app/
```

Foundry is pinned to `nightly-975a456ef42ab506b8d343df5541a248798c5a27` in CI and for every gas
figure here; `@1inch/solidity-utils` is held at 6.9.10 through `resolutions`; the console's toolchain
lives in `script/vendor/` because a `yarn add` at the root re-resolves the 1inch pins and breaks the
contract build. The precompiles carry no bytecode, so a fork cannot call them and tests etch mocks;
`forge script` cannot send a swap here at all. What the node does that no local test can see is
[`docs/hyperevm-notes.md`](docs/hyperevm-notes.md).

## What this does not answer yet

- **Demand.** Every fill on chain 999 is one this repository sent, on a schedule, and the artifact
  says so in `source.demand`. The clamp is checkable on one fill against one receipt and who stood on
  the other side does not enter the arithmetic; but nothing here measures demand, profitability or
  adverse selection.
- **A hedged desk's P&L.** The replay has no perp leg. Its markout and the cover leg do not add.
- **A cascade on mainnet.** The switch is on chain and can be pressed — the map button flips the
  demo desk into its absorbing regime in the current block. The cascade itself is on the tape, because
  there has not been one since the desks went live.
- **The comparator's limit.** Against ordinary flow with a fast oracle, an oracle-pegged maker and
  this desk are indistinguishable; the difference is what each does when the book and the oracle
  disagree. The argument does not turn on which control is picked: loss-versus-rebalancing is a
  property of any maker whose price is a function of its own reserves or of a price it read earlier.
- **Uniswap.** [`test/v4/`](test/v4/) expresses the same rule as a v4 `beforeSwap` hook against a mock
  reader, and it passes; what is missing is a chain where both the venue and the book exist.
  [`FEEDBACK.md`](FEEDBACK.md) is what came out of writing it.

## AI usage

AI assistance was used throughout this repository. [`AI-USAGE.md`](AI-USAGE.md) says which models did
what, on which parts, and what was done by hand. Every commit was reviewed, made and pushed by the
author; the mechanism, the parameters and every transaction on chain 999 are his.

## Prior art

- Milionis, Moallemi, Roughgarden, Zhang, arXiv:2208.06046 — *Automated Market Making and
  Loss-Versus-Rebalancing*. This desk attacks one channel of it: extraction against a price set
  before the trade.
- Milionis, Moallemi, Roughgarden, arXiv:2305.14604 — fees scale the loss down; they do not remove
  the gap that causes it.
- P1, arXiv:2607.27070 — no early warning exists; the regime here is a nowcast, not a forecast.
- P2, arXiv:2608.03616 — the venue backstop absorbed most of the 10 October cascade; this is public
  absorber capacity.
- Chitra, arXiv:2512.01112 — auto-deleveraging is what happens when absorbers run out.
- Bouchaud, arXiv:1412.0141 — mechanical impact decays; the markout clock.
- 1inch Aqua and SwapVM; Hyperliquid's HLP; HumidiFi; Ballast; MEV-X.
