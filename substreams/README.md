# coldcascade substreams

The desk's own record, off HyperEVM blocks.

coldcascade is a 1inch Aqua maker program on chain 999 that prices against Hyperliquid's L1 order
book *inside* the swap. Every fill it makes therefore carries the book it filled against, in the
same log — bid, ask, mark and oracle as `CoreQuote` read them while pricing that swap.

That is the whole reason this package exists. The markout of a fill is the move of L1 mid between
the instant the desk quoted and some later instant, signed from the maker's side. The left-hand
side of that join is in the `Fill`. The right-hand side has to come from a `Booked`, because the
HyperCore precompiles ignore the block tag: an `eth_call` to `0x080e` pinned two hundred thousand
blocks back answers with the *current* book. They are node state, not chain state, so there is no
archive read and no way to ask what the book was. `BookCache.poke` writes the four words into a
log while they are current, and this package is what reads them back.

## Modules

| | |
|---|---|
| `index_desk_events` | one key per contract that spoke in a block |
| `desk_events` | `Fill`, `Booked`, `MapUpdated` and `Markout`, decoded, one message per block |

`desk_events` filters on the index. The desk went live at block 45 135 453; a scan to head is a
quarter of a million HyperEVM blocks, of which a couple of dozen contain anything of ours.

## Build

```
cargo build --release --target wasm32-unknown-unknown
substreams pack substreams.yaml
```

## Run

Against The Graph Market for Substreams, whose HyperEVM endpoint is Pinax's:

```
export SUBSTREAMS_API_TOKEN=...
substreams run -e hyperevm.substreams.pinax.network:443 \
  coldcascade-v0.1.0.spkg desk_events -s 45135453 -t 0 --limit-processed-blocks 0
```

`keeper/coldcascade/markouts.py` consumes exactly that, joins each fill to the books that follow
it, and posts the result to `MarkoutLedger` — whose `Markout` log this same package then decodes.

## Decoding

Written out rather than generated. All four events are static ABI — no dynamic field in any of
them — so the decode is fixed offsets, and a codegen step would be one more thing that can
silently disagree with the contracts in `src/`. The topic hashes are `keccak` of the signatures
and are checked against `cast keccak` output in the same session they were written.

## The MCP server

`mcp/` serves this package over the Model Context Protocol: the book archive as a
queryable archive, and the desk record with its derived fields. `mcp/SKILL.md` is the manual for
both, and the server serves it as a resource at `coldcascade://skill`.
