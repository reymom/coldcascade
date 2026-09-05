# coldcascade

A maker program on 1inch Aqua, on HyperEVM, whose quote is bounded by Hyperliquid's own book and
leans into liquidation cascades.

HyperEVM is the only chain where Aqua is deployed and a contract can read the perp book in the
same call: `0x0806` mark, `0x0807` oracle, `0x080e` best bid and ask, as precompiles. Aqua's
HyperEVM deployment has no makers. This is the first program that quotes against that book.

The program is `XYCSwap || Extruction(CoreQuote)` on the official SwapVM router. `CoreQuote`
reads the book in the quote itself. In the quiet the desk sits outside L1, so it cannot be taken
stale. When the book dislocates from oracle, or a fresh liquidation map says mark is walking into
forced flow, the absorbing side moves inside the spread and warehouses the overshoot. Aqua
custodies nothing.

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

One URL. The Floor shows Hyperliquid's BTC book as `CoreQuote` reads it, the desks quoting against
it, and a Take button that swaps through the official router. It is live before the contracts are:
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
- Two gates, and they are different questions. `test_deathMetric_amountOutMovesWithBook` asks
  whether a swap responds to the regime at all. `test_gate_absorbedEdgeBeatsControl` asks whether
  the session's absorbed notional actually reverted in the desk's favour by a multiple of the
  control's — a desk can pass the first and still draw two flat lines. When the second one fails,
  the taker model is the suspect before the quote is.

## Prior art

- P1, arXiv:2607.27070 — no early warning exists; this is a nowcast, not a forecast.
- P2, arXiv:2608.03616 — the venue backstop absorbed most of the cascade; this is public absorber
  capacity.
- Chitra, arXiv:2512.01112 — auto-deleveraging is what happens when absorbers run out.
- Bouchaud, arXiv:1412.0141 — mechanical impact decays; the markout clock.
- 1inch Aqua and SwapVM, HumidiFi, HLP, Ballast, MEV-X: cited in the design notes to come.
