# app

The console. Two tabs, no framework and no build step: ES modules and one stylesheet, served as
static files.

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

The replay, unchanged, imported only when the tab is first opened. It reads
`../results/oct10_replay.csv` and is labelled a reproduction from a frozen tape — nothing on a live
screen is a picture of something else.

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
| `src/rpc.js` | JSON-RPC, the state override, the injected wallet |
| `src/chain.js` | every call the Floor makes, with its type strings in one place |
| `src/floor.js` | the Floor screen and the two buttons |
| `src/bands.js` | the live two-books strip |
| `src/replay.js` · `src/chart.js` · `src/app.js` | the Evidence tab, unchanged |
| `src/types.ts` | the contract and CSV types, for the surfaces still to come |

Regenerate the two JSON files after any change to `CoreQuote`, `FloorLens`, `DeskAccount`,
`DeskFactory`, `MapOracle` or `DemoToken`:

```
forge build && ./script/appdata.sh
```
