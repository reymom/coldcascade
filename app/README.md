# app

The console. Two tabs, no framework and no build step: ES modules and one stylesheet, served as
static files.

## Signing in

A visitor types an email address, receives a six-digit code, and has a wallet on the chain this page
is reading. No extension, no seed phrase, no funding step — which is the taker path the console is
meant to be judged on, because a maker program nobody can take is a paper.

- **The wallet is a Privy embedded wallet.** `src/signer.js` reduces it and the browser's injected
  wallet to the same five members, so Take and the map poke are written once and neither knows which
  key it is holding.
- **The chain is a constructor argument.** The Privy client is built with `supportedChains` of
  length one, and that one is `chainFor(chainId, rpcUrl)` where `chainId` is the `eth_chainId` the
  page connected to. An embedded wallet has no other chain it could be on, so "is the wallet on the
  right chain" is not a question this path can get wrong — see the note at the top of `src/signer.js`
  for the bug that shape is there to prevent.
- **Gas.** A wallet minted from an email address holds no HYPE and Privy's gas sponsorship does not
  cover chain 999, so `../api/faucet.mjs` drips 0.002 HYPE — once per *Privy user*, not per address,
  because an address is free to mint. It signs with a Privy server wallet under a policy that allows
  `eth_sendTransaction` on chain 999 up to that amount and nothing else; `../keeper/policy.json` is
  that policy as Privy returns it. `node ../test/api/faucet.test.mjs` asserts what it refuses.
- **The SDK is loaded lazily and vendored, never from a CDN.** `vendor/privy.js` is 836 kB of
  somebody else's JavaScript and the Floor does not pay for it: the book, the desks and the round
  trip are this repository's own code against a node. It is fetched when a visitor asks for a
  wallet, and on a reload only when Privy's own refresh token is in `localStorage`.

## Floor — live

The landing screen, and it is live before anything is deployed.

- **The book** is four words out of `0x080e`, `0x0806` and `0x0807` on chain 999, read by
  `CoreQuote` itself — not by the page. Nothing here is a price feed.
- **The desks** are rows of `FloorLens.floor()`, one `eth_call` for the whole screen. That is
  deliberate: the precompiles ignore the block tag (`../results/999_live_quote.md`), so reading the
  book and then reading a desk's bounds returns two different books, and one 10-raw tick between
  them puts a band on screen that contradicts its own arithmetic.
- **The two books** is the Oct-10 tab's picture on one instant. The ghost outline is where a desk
  sits when it is not leaning, so the distance it travelled to get inside L1 is on the screen.
- **Take** reads the order back from the account with `order()`, quotes through the official SwapVM
  router, approves `tokenIn` to the router and swaps. The page never rebuilds an order.
- **Post a liquidation map** is the one trusted input, exposed rather than described. See below.

### Two modes, and the page says which

| chip | what it means |
|---|---|
| **live** | `../deployments/<chainId>.json` exists. The rows are `DeskAccount`s holding tokens, and Take works. |
| **simulated** | Nothing is deployed on this chain yet. `CorePrecompiles`, `CoreQuote` and `FloorLens` are planted at throwaway addresses by an `eth_call` state override and the canonical *parameters* are priced with no account behind them. |

Simulated mode is not a mock. The bytecode planted is what `forge build` produced, the node
executing it is a real one, and the book it reads is the live book — it is the same three
`eth_call`s `../script/probe999.sh` makes from a shell. `CoreQuote` takes its reader as a
constructor argument, so its runtime does not exist in any artifact; the page gets it by running
the creation code through an `eth_call` with no `to` and keeping what comes back.

### Two layers, and only the tokens are mocked

The **canonical** desk trades the real pair and names `MapOracle`, which has one updater. The
**demo** desk trades `DemoToken`s anyone can mint and names `DemoMapOracle`, which anyone can write.
Both price against the same live HyperCore book. The map column says which oracle a desk names,
because that difference is the whole trust argument: a desk quoting inside L1 is offering a better
price than L1, so an oracle anyone can write is an oracle anyone can be paid out of.

That is why the map button works for a visitor on the demo desk and not on the canonical one, and
why the page says so instead of hiding the control.

## Evidence · 10 October 2025

The replay, imported only when the tab is first opened. It reads `../results/oct10_replay.csv` —
45 columns, documented in `../results/oct10_replay.schema.md` — and is labelled a reproduction from
a frozen tape, because nothing on a live screen should be a picture of something else.

**It is the Floor's claim over a session rather than over a block.** The Floor prices one round
trip against the current book; this counts what an arbitrageur closing at L1's own touch actually
extracted over 123 consecutive minutes of the 2025-10-10 cascade. Both come out zero, and the zero
is the headline: $0 taken from the desk against $3,558 from a plain `XYCSwap` control and $2,700
from the same curve charging 30 bps, and 0% of the desk's traded notional was that arbitrageur
against 98.5% of theirs.

That zero is one adversary against one book in the same minute — the channel the clamp is aimed
at, which is what the CSV's `lvr*` columns are named for. A taker who is right about the next
minute is inventory risk instead, and lands in the markout.

**There is no perp leg on this tab.** The edge lines are the markout of inventory each maker kept,
which does not sum with a hedge: a spot leg bought at `P`, a short opened at `H`, both marked at
`M`, combine to `q × (H − P)`. The cover leg is a different measurement, on chain 999, in the root
`README.md`.

There is no multiple on the page. Both AMM lines lose money on what they absorbed — which is what
a maker whose price was set before the trade does in a cascade — so the honest denominator does
not exist. Four lines instead: the desk, the plain control it is an ablation of, the fee'd control
that is the competitor, and Hyperliquid's own touch, which is not a maker and is the only
comparison nobody can call a strawman. The desk ends above it, on a third less notional.

The last section on the page declares the one modelled quantity the numbers rest on — the width of
the stub tape's book — and measures what it is worth rather than apologising for it.

## Running it

The page fetches JSON and a CSV, so it needs a server rather than `file://`. From the repository
root:

```
python3 -m http.server 8000
```

then <http://localhost:8000/app/>. It reads mainnet by default; `?rpc=` points it anywhere,
which is how it is used against the local fork:

```
./script/localnet.sh                       # fork 999, deploy, ship, swap
open http://localhost:8000/app/?rpc=http://127.0.0.1:8545
```

## Shape

| file | |
|---|---|
| `index.html` | both tabs and all of the CSS |
| `selectors.json` · `bytecode.json` | written by `../script/appdata.sh` out of the compiled artifacts. **No selector and no bytecode is typed into JavaScript** — a signature that drifts from a contract fails that script instead of producing a call a router silently rejects |
| `src/console.js` | the tab shell |
| `src/abi.js` | the ABI codec, written rather than imported. The page sends calldata to a router; a CDN import would put a third party between the judge's browser and those bytes |
| `src/rpc.js` | JSON-RPC and the state override. No chain constant lives here |
| `src/signer.js` | the two wallets behind one interface, and the chain description both are built from |
| `vendor/privy.js` · `privy.json` | written by `../script/appvendor.sh`: the bundled SDK and the public app id, which is read out of `.env` rather than typed. **The app secret is a Vercel environment variable and is in neither** |
| `src/chain.js` | every call the Floor makes, with its type strings in one place |
| `src/floor.js` | the Floor screen and the two buttons |
| `src/bands.js` | the live two-books strip |
| `src/replay.js` · `src/chart.js` · `src/app.js` | the Evidence tab: the CSV guard, the drawing primitives, the four lines |
| `src/types.ts` | the contract and CSV types, for the surfaces still to come |

Regenerate the two JSON files after any change to `CoreQuote`, `FloorLens`, `DeskAccount`,
`DeskFactory`, `MapOracle` or `DemoToken`:

```
forge build && ./script/appdata.sh
```

and the vendored SDK plus `privy.json` after a change to `PRIVY_APP_ID` or to
`script/vendor/package.json`:

```
./script/appvendor.sh
```

That toolchain lives in `../script/vendor/` with its own lockfile on purpose. A `yarn add` in the
root package re-resolves the pinned 1inch GitHub dependencies — it rewrote `@1inch/swap-vm`'s own
dependency edges, installed a different tree, and `forge build` stopped finding `ProgramBuilder.sol`.
A JavaScript bundler cannot be allowed to break the contract build.
