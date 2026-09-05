# app

The Oct-10 tab, built. It reads `results/oct10_replay.csv` and draws three things:

- **spot** — Coinbase 1m closes, so the crash itself is on the screen.
- **the two books** — Hyperliquid's own bid–ask and the desk's own bid–ask, both as distance from
  L1's mid in basis points. That is the only scale on which a 25 bps quote and a $7 000 crash fit
  in one picture. In the quiet the desk's band encloses L1's on both sides: it is never the best
  price on the screen, so a stale quote is not worth taking. Under stress one side crosses inside
  and the wedge is filled — amber buying from forced sellers, teal selling to forced buyers.
- **60 minute markout** — each minute's fills against spot an hour later, desk against the plain
  `XYCSwap` control.

Hovering anywhere reads out that minute: both books, the lean, the dislocation, the forced
notional on each side and the markout.

## Running it

The page fetches the CSV, so it needs a server rather than `file://`. From the repository root:

```
python3 -m http.server 8000
```

then open <http://localhost:8000/app/>. To regenerate the data it draws:

```
forge test --match-contract Oct10Replay
```

## Shape

No framework and no build step: three ES modules and one stylesheet.

| file | |
|---|---|
| `index.html` | the page and all of its CSS |
| `src/replay.js` | the CSV loader. Throws `SchemaDrift` if the header is not the frozen 30 columns, so a schema change fails here instead of drawing a wrong picture quietly |
| `src/chart.js` | scales, axes, bands, lines. Enough SVG for charts that share an x axis, which is less code than configuring a library |
| `src/app.js` | the four panels and the readout |
| `src/types.ts` | the contract and CSV types, mirroring `src/libs/DeskParams.sol` and the replay schema. For the Provide and Take surfaces, which are not built yet |

Still to come, in this order: the landing page reading a live desk over the subgraph, Provide
(wallet, `approve`, `ship()` of the canonical program) and Take (one swap through the official
router).
