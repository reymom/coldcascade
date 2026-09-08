# The public node has no past — chain 999, 8 Sep 2026

`BookCache` exists because the HyperCore precompiles ignore the block tag: an `eth_call` to
`0x080e` pinned two hundred thousand blocks back answers with the *current* book
(`results/999_precompile_block_tag.md`). They are node state, not chain state.

The same property turns out to hold for **ordinary contract storage** on the public endpoint, which
is a separate and more surprising fact — a precompile with no bytecode is at least visibly special,
whereas an ERC-20 balance is not.

## Measured

`balanceOf` of the demo desk's base token, at four blocks spanning 145 000 of them, two of which
contain fills that changed it:

| endpoint | @45 193 088 | @45 276 523 | @45 338 605 | latest |
|---|---|---|---|---|
| `rpc.hyperliquid.xyz/evm` | 205 324 615 | 205 324 615 | 205 324 615 | 205 324 615 |
| `rpc.hypurrscan.io` | 205 324 615 | — | — | 205 324 615 |
| `hyperliquid.drpc.org` | **198 757 764** | — | — | 205 324 615 |
| `rpc.purroofgroup.com` | **198 757 764** | — | — | 205 324 615 |

The block tag is accepted and ignored rather than refused, so a reserve read against the public
node is silently the wrong number instead of an error. That is the dangerous shape: nothing fails.

## Why 198 757 764 is the right answer

The desk was shipped with 200 000 000 raw base. Block 45 193 088 contains
`0x9407579f…537c`, in which the desk sold 1 242 236 raw base. `200 000 000 − 1 242 236 =
198 757 764`. Walking every fill in the stream forward from the ship amounts reproduces both
reserves at every fill, exactly, against the archive endpoints — which is what
`keeper/coldcascade/markouts.py` relies on to compute `poolDevBps`.

## Consequence

`ARCHIVE_RPC_URL` is a separate setting from `KEEPER_RPC_URL` for this reason, and the keeper reads
reserves only through it. The pool's deviation from L1 at the moment of a fill is not in the `Fill`
event and cannot be recovered from the public node; it needs an archive read of the two balances at
`block - 1`, and the L1 price it is compared against comes from the fill's own `oracle` word.
