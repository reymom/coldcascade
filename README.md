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
indexed data alone. After emitting, a maker with code is handed `onFill` under a 250 000 gas cap
with every failure caught. By then the taker has been paid, so **cover can never fail a fill** — a
maker that reverts on every callback still gets filled, and one that burns everything it is handed
costs the taker the cap rather than its budget. Both are tests.

## Status

The quote, the program encoder and the desk account are built and tested against 1inch's own Aqua
and router. The HyperCore reader has been run against a live node. Deployment, the console and the
CoreWriter cover leg are next; the numbers arrive when the replay runs on a real tape.

## Build

```
yarn install --frozen-lockfile --ignore-scripts
forge build
forge test
```

- Foundry `nightly`. `@1inch/aqua` and `@1inch/swap-vm` resolve from GitHub at pinned commits;
  `@1inch/solidity-utils` is held at 6.9.10 through `resolutions`, because Aqua's 6.9.7 is
  missing `TransientLockUnsafe.sol`.
- HyperEVM mainnet is chain 999 (gas 0.1 gwei), testnet 998. `eth_getLogs` caps at 1000 blocks.
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
