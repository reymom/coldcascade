# On chain 999

The deployment, the first swap through the router, the clamp transaction and its arithmetic, the taker wallet, the address book, and the death metric on the deployed router.

## The deployment

The quote, the program encoder, the desk account and the console are built and tested against
1inch's own Aqua and the SwapVM router deployed on 999. The HyperCore reader has been run against a
live node, and the round trip above is the live book answering today. **It is deployed.** Fifteen
contracts on chain 999 — twelve on 6 September and three more with the hedge leg on the 7th — four
desks shipped and open, and the canonical desk holds real UBTC and USD₮0. The taker path is live end to end from an email address, and the CoreWriter
cover leg has been sent from a desk and filled on HyperCore. A desk can hand that trigger to an
automation key that may call `cover()` and nothing else — on chain and under a policy — and one on
999 did: it absorbed a fill, and five minutes later a cadence covered it with no signature from
anyone. The desk's own record is indexed off Substreams and the keeper posts markouts back to the
chain, described below.

Every fill on chain so far is one we sent; there is no external flow yet.

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

The pool ratio at that moment was 81 003, so `XYCSwap` alone would have paid **+163.6 bps over L1's
bid** — free money for whoever took it. That is the same quantity the artifact reports as
`poolDevBps` 160.8, measured against the oracle instead of the bid; the ~2.8 bps between them is
where the book sat relative to oracle in that block. Two denominators, one pool. The bound cut it to
L1's own bid less the band and stopped there.
That is the whole mechanism in one transaction: against the book read in that call, the desk is
never a better price than crossing L1.

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
node-level failures it hit are in [`results/999_deploy.md`](../results/999_deploy.md).

**The death metric, on the deployed router.** Against a fork of 999 carrying the real Aqua and the
real SwapVM, two swaps of 1 000 quote units into the same desk with the book moved between them:
`amountOut` went from 1 242 236 at a 799 500 / 799 510 book to 1 226 899 at 810 000 / 810 010. Both
settled through `swap()` and emitted `Fill` with the four L1 words in it. Reproduce with
`./script/localnet.sh` — it prints the two commands.

