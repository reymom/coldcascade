# Feedback for the Uniswap Foundation

Written from building a market-making program on HyperEVM whose quote reads the perp venue's own
book inside the swap. What the Uniswap stack can and cannot express about that.

## What was built, in one paragraph

A maker on 1inch Aqua, on HyperEVM, whose quote is a function of Hyperliquid's own perp book read
inside the call that settles the swap: best bid and ask from precompile `0x080e`, mark from `0x0806`,
oracle from `0x0807`. The rule is short. Quote outside L1 in the quiet; when mark walks away from
oracle, or a liquidation map says forced flow is coming, move the absorbing side inside L1's spread;
and whatever the curve or the lean wanted, never pay more than crossing L1 would have paid in that
same call. It is deployed on chain 999, takes real fills through 1inch's router, and hedges through
Hyperliquid's CoreWriter from the same contract. None of it runs on Uniswap and none of it can: v4's
PoolManager is on 24 chains (17 mainnets, 7 testnets, deployments page read 2026-09-08) and HyperEVM
is not one of them, and HyperEVM is the one chain where a contract can read that book. What is in
this repository for Uniswap is the same rule written as a v4 `beforeSwap` hook with a return delta,
in `test/v4/`, against a mock reader, with v4's accounting reproduced around it — and this document,
which says what that exercise found. The rule is `src/libs/Regime.sol` (`classify`, lines 49–68) and
`src/CoreQuote.sol` (`extruction`, lines 60–110; the clamp is line 99). The hook is
`test/v4/CoreQuoteHook.sol`; the tests are `test/CoreQuoteHook.t.sol`.

## Liquidity curated by price is not the only axis

v3's contribution was letting a provider say *where* their capital works. A tick range is a
statement about price, and every position type since carries that axis and no other: v4's
`ModifyLiquidityParams` still begins with `tickLower` and `tickUpper`. This desk curates on a
different one. Its inventory band — `minBase` and `maxBase` in `DeskParams` — is a range on
inventory, and its price is not a function of a pool price at all. It is a function of the state of
the reference market: how far mark has walked from oracle, and how much forced notional sits within
1% of mark. `Regime.classify` is the curation function. Its inputs are the book, the map and the
maker's thresholds; its output is a side to lean. There is no tick in it.

The distinction is not cosmetic, and the replay in this repository is where it shows. On 123
minutes of the 10 October 2025 cascade, against takers that cannot see which maker is which, two
things decide the desk's result and they are separable: the regime decides how much the desk
trades, and the clamp decides that none of it is a profitable round trip against the book it read.
Sweeping the regime threshold moves what the desk absorbs from $43,173 to $0; the arbitrage column
is $0 at every rung. A tick range conflates the two, since it is at once where you trade and at what
price. A fee tier is a third thing again: it scales the loss to a better-informed price down and
does not remove the gap that produces it (Milionis, Moallemi, Roughgarden, arXiv:2305.14604). A
bound at the reference venue's touch, applied in the call, removes that one channel. That is what
"curated by book state" means here, and it is the axis I would want a position type to be able to
say: a price function and an inventory band, with the pool as the place it settles.

## A quote that reads a perp book: the hook interface handles it, the deployment topology does not

What the interface expressed, each with a test behind it:

- **The rule fits in `beforeSwap` with `BEFORE_SWAP_RETURNS_DELTA_FLAG`.** A specified delta of
  `-amountSpecified` makes `amountToSwap` zero, `Pool.swap` answers a zero amount with no delta, and
  the unspecified delta carries the maker's leg. Exact-in and exact-out are the sign of
  `amountSpecified`; the bid side is which currency is the input.
  `testFuzz_theHookAndTheExtructionAgreeToTheUnit` runs the hook and the deployed Extruction over a
  fuzzed book, both sides, both directions, 1 024 runs, and gets the same number to the unit.
  `test_theCurveNeverParticipates` checks that the pool's reserves did not move.
- **The bound survives the accounting.** `testFuzz_noRoundTripEverProfits_inTheV4Frame` takes the
  swapper's `BalanceDelta`, closes it at L1's touch in the same book, and never finds a profit — the
  property `test/Inarbitrable.t.sol` holds on the Extruction, held again with v4's delta arithmetic
  between the taker and the rule.
- **One permission bit is the whole design.** `test_withoutTheReturnsDeltaBit_theQuoteNeverReachesTheSwap`
  plants the same hook at an address without the returns-delta bit. The manager calls it, it
  answers, `Hooks.beforeSwap` skips the answer, the pool's own curve fills, and after a 12% move
  that curve is worth 1 352 bps to an arbitrageur in one round trip while the hook with the bit is
  worth exactly zero, leaning, on L1's own offer. The rule is expressible only as a hook that *is*
  the maker. A hook that merely watches the book is a dynamic-fee hook, and a fee is not a bound.
- **The maker's commitment can be frozen.** The parameters are constructor-set and there is no
  setter. Aqua does this by hashing the strategy at `ship()`; a hook does it by having no code path
  that writes. Inventory is the hook's own balances, which is what Aqua's virtual balance is to the
  desk, and the band check reads them the same way (`test_theInventoryBandSurvivesTheFrame`).

What it did not express, and what "topology" means:

- **There is no chain where both halves exist.** HyperEVM has the book as precompiles and no
  PoolManager; the chains with a PoolManager are chains where the reference book is somewhere else.
  The `ICoreReader` seam makes this exact. Three things fill it: `CorePrecompiles` (the live book,
  three capped staticcalls, 10 761 gas measured on chain 998), `BookCache` (the same four words, one
  poke stale), and an adapter over a price feed. `test_oracleReader_cannotLean` is the third row: one
  mid copied into four words, `oracle − mark` identically zero on a minute where the book reads 142
  bps, no lean ever, and no bid or ask for the clamp to stop on. Deploying this hook on a chain with
  a feed does not port the mechanism; it keeps the type and deletes the rule. Latency between a feed
  and a book is not the issue. A mid is not a book.
- **The curve and the bound cannot see each other in one callback.** In SwapVM the desk is
  `XYCSwap || Extruction(CoreQuote)`: the curve runs first and hands its answer to the bound in a
  register, so the desk is `min(curve, bound)` in the quiet and `max` in a lean — the curve is a
  first opinion the book edits. In v4 the curve runs *between* `beforeSwap` and `afterSwap`. Editing
  its fill means taking it back in `afterSwap` with a second return delta; paying more than it did
  means paying from the hook's own inventory. Two callbacks, two inventories, and an LP position that
  no longer describes what the maker committed. The hook in `test/v4/` takes the other road and
  zeroes the curve, which is honest, and which turns the pool into a settlement layer for a maker
  that lives in the hook. That is Aqua's shape — the maker keeps custody, the venue custodies
  nothing — rebuilt by hand inside a venue designed around the opposite.
- **`beforeSwap` is not `view`.** SwapVM declares `IStaticExtruction.extruction` `external view`
  and quotes through STATICCALL; one body answers `quote` and `swap`, and the suite asserts at the
  router that they agree. The hook here is `view` — Solidity permits the stricter override — but
  nothing in v4 lets a quoter rely on it: the price of a return-delta hook is learned by simulating
  the swap. For a hook whose answer comes from a precompile that a fork cannot serve, that
  simulation is a real question; for the SwapVM path it took a probe against a live node to answer
  (`results/998_precompiles.md`).
- **Gas is not the obstacle.** The book read is three precompile frames, 10 761 gas on chain 998; a
  whole swap through the SwapVM router with the read inside it cost 194 108 gas on chain 999
  (`0xfaf1b6c6…ab20`) and the fill landed 20.00 bps under the L1 bid, which was its parameter to the
  basis point. Whatever the topology, `beforeSwap` has the budget.

A naming note, since a Uniswap reader will trip on it: `src/DeskHooks.sol` is 1inch's
`IMakerHooks`, the post-transfer-out callback that emits the fill. It is not a v4 hook. The v4 hook
is `test/v4/CoreQuoteHook.sol`, and it is only there.

## Continuous Clearing Auctions and demand spikes: the open question

CCA, per its README, "generalizes the uniform-price auction into continuous time" and exists for
"bootstrapping initial liquidity while eliminating timing games and encouraging early
participation." The technical documentation is precise about the mechanism: supply is released on a
per-block schedule in milli-bips of total supply; bids are `(maxPrice, amount)` and "must be
strictly above the current clearing price"; checkpoints happen at most once a block; the clearing
price is "the lowest clearing price at which all remaining supply over the remaining schedule can
be sold to demand at or above that price." Demand above the price rolls forward, so the price
ratchets up, and nothing in the document lowers it. At graduation `lbpInitializationParams()` seeds
a v4 pool. It says nothing about the secondary market, and does not claim to.

The question this repository can ask that a launch cannot: a liquidation cascade is a demand spike
with the sign flipped. On 10 October 2025 spot moved 12% and forced sellers arrived over minutes —
the Coinbase minute bars in `tape/` are real; the perp book in the replay is modelled from that
path, and the README says so. The desk's answer is to price each clip against the reference book in
the call that settles it, and the replay says what that is worth against blind takers on 1inch's
router: $56,898 of forced flow, of which the desk absorbs between $43,173 and $0 depending on its
threshold, with an arbitrage column of $0 throughout. CCA's answer to a spike is different in kind:
clear the participants against each other over time rather than against a maker's price in the
instant. It is not obvious which is better for the seller being forced out, or that they exclude
each other. Concretely:

1. **The mechanism as documented is one-sided and monotone.** Supply is scheduled and bids clear
   upward. A cascade is the mirror: forced *supply* arriving unscheduled, absorbers as the bids, and
   a price that has to clear downward and then back. Does the clearing rule generalize to that, or
   is the ratchet load-bearing?
2. **Block-granular clearing against a book-bounded floor.** The desk's clamp is "never a better
   price than crossing L1." A CCA whose floor were that clamp, re-read at every checkpoint, would
   clear forced flow against itself *and* never through the reference — the property this
   repository holds in every block. Is `IValidationHook.validate(maxPrice, amount, owner, sender,
   hookData)` the place for that, or does the floor need to move with the book, which the
   validation hook cannot do?
3. **Measurement.** The replay harness here — blind takers, the official router, 45 published
   columns — can run a clearing maker in the desk's slot on the same tape. It has not been run. It
   would be the first test of whether continuous clearing softens the spike it was not built for,
   and it is the experiment I would bring to the hook incubator, whose applications close on
   21 September 2026.

## What would have made this easier

Against the Developer Feedback Form's own questions.

- **"Were you able to successfully integrate Uniswap?" No, and the blocker was a chain, not an
  interface.** The deployments page said in one read that HyperEVM is absent. What it could not say
  is which of the 24 chains has any market state a hook can read in the call. An environment
  matrix — chain, PoolManager, what a contract can `staticcall` about the market there — would have
  answered in minutes what took a registry check and a probe against a node. And bluntly: a chain
  with a perp book readable from the EVM and no Uniswap on it is the most obvious place a hook that
  curates by market state could be true. That is a deployment decision, and this is the argument
  for it.
- **A reader seam in the hook templates.** The single most useful design decision in this
  repository was `ICoreReader`: three implementations, one immutable, and the same rule tested
  against the live shape, the cached shape and the feed shape. Hook scaffolds hardcode the oracle.
  A template that injects it would let every price-aware hook state, in a test, what it degrades to
  on a chain without its source.
- **A dependency-free way to unit-test a return-delta hook.** `test/v4/PoolManagerStub.sol`
  reproduces `Hooks.beforeSwap`, `Pool.swap`'s zero-amount return and `Hooks.afterSwap`'s fold,
  because adding v4-core to a repository pinned to 1inch's dependency graph is a risk the README
  already documents from the last time an install re-resolved it. The delta arithmetic and the flag
  constants in one importable file, with no PoolManager behind them, would make a hook's pricing
  testable in any repository.
- **The sign table.** Which currency is specified, what sign the hook returns to take or give it,
  and how `(params.amountSpecified < 0 == params.zeroForOne)` maps the pair onto `(amount0,
  amount1)`: all of it is in `Hooks.sol`, and I read `Hooks.sol` to be sure. One table would have
  saved the hour.
- **A statement about quoting.** Whether a return-delta hook can be quoted without a state-changing
  simulation, and if not, say so. SwapVM's `view` extruction made the equality of quote and swap a
  one-line test; v4 made it a question about the quoter.
- **The form has no field for this.** Its questions assume a project that integrated and a
  documentation gap that slowed it. The most useful thing a builder can sometimes report is that the
  interface handled the rule and the topology refused it, with a test for the first half. This file
  is that report; the form is where the link goes.
