# The stream against the receipt — chain 999, 8 Sep 2026

The `substreams/` package decodes `DeskHooks.Fill` from HyperEVM blocks. This is that decode set
beside the receipt the node serves for the same transaction, field by field, so the claim "the
stream carries the book each fill filled against" is checkable rather than asserted.

The transaction is `0xfaf1b6c6…dab20`, block **45 195 770** — the mainnet swap where the clamp,
and not the curve, set the price.

## The command

```
substreams run -e hyperevm.substreams.pinax.network:443 \
  substreams/coldcascade-v0.1.0.spkg desk_events -s 45195770 -t +1 -o json
```

## Fill(bytes32,address,address,address,address,uint256,uint256,uint64,uint64,uint64,uint64,uint128,uint128)

topic0 `0x999a9e88f019c1cef3020b109937c254b0474953cfe1b5dfbcc1d38ab5d00b77`, emitted by
`DeskHooks` at `0x84C1D720787F7D197dfc2890862E69c42aB0A363`.

| field | receipt (`eth_getTransactionReceipt`) | Substreams `desk_events` | |
|---|---|---|---|
| `orderHash` (topic 1) | `0xa0f7ca13…f25d6` | `0xa0f7ca13…f25d6` | = |
| `maker` (topic 2) | `0xc76137e49bf4d323190a4ee694b47d5a2ac515b2` | same | = |
| `taker` | `0x9d597ddfb34654592ab9ae6c1185bca7fc4e6e85` | same | = |
| `tokenIn` | `0x42e5aab590c822a13d58e21bb275d0a47d97401b` | same | = |
| `tokenOut` | `0xb89d8429ebfdd342c2a7f931c603138aa8d17670` | same | = |
| `amountIn` | 1 000 000 | 1 000 000 | = |
| `amountOut` | 795 396 020 | 795 396 020 | = |
| `bid` | 796 990 | 796 990 | = |
| `ask` | 797 000 | 797 000 | = |
| `mark` | 796 980 | 796 980 | = |
| `oracle` | 797 210 | 797 210 | = |
| `mapBelow` | 0 | 0 | = |
| `mapAbove` | 0 | 0 | = |

Eleven data words and two indexed topics, all equal.

## And the number that falls out of it

The taker sold 1 000 000 raw dUBTC and received 795 396 020 raw dUSDT0, so the desk bought base at

```
795 396 020 / 1 000 000 × (pxDen / pxNum = 1000) = 795 396.02 raw L1 px
```

against an L1 bid of **796 990**:

```
(795 396.02 − 796 990) / 796 990 × 10 000 = −20.0000 bps
```

which is the desk's own `quietBps`, read off its frozen `DeskParams` on the same chain. The
keeper reports this per fill as `vsTouchBps`. It is a price statement, not a P&L: negative means
the desk bought below the bid, positive means it sold above the ask, and either way the magnitude
is the clamp.

## The book series

`BookCache.poke` had never been called on mainnet before 8 Sep 2026 — `pokedAt(0)` returned 0 and
there was no `Booked` event on chain 999. The first is
`0x24dbe44600cf312191545159a42e9ef14acd26df85412088e9aead2ecf9ab60d`, block 45 357 494. Every
fill in the table above predates it, which is why none of them carries a markout: the join has a
left-hand side and no right-hand side. The record starts with the series.
