# The console

The four tabs, the taker path from an email address, the gas faucet and the three things a Privy policy needs before it binds, and the two layers of desks.

## The console

One URL, four tabs. **The Desk** leads with the live round trip — recomputed off the book every
two seconds, and the reason the quiet screen is the evidence rather than the absence of it — then
Hyperliquid's BTC book as `CoreQuote` reads it, the desks quoting against it, a map button that
puts a desk into a lean so the other half is on the screen on demand, and a Take button that swaps
through the official router. **The Record** is every fill against the band, the keeper's decisions
and the book archive. **The Cascade** is the film and the replay of 10 October 2025. **The Keys**
is the two live shorts and what the operator's wallet refuses.

**Taking a desk needs an email address, or a Discord account, and nothing else.** Type one, receive a six-digit code, and a
Privy embedded wallet appears on the chain the page is reading — then mint the demo token, approve
the router, swap. Three transactions, no extension, no seed phrase, no funding step. A wallet minted
this way holds no HYPE and Privy's gas sponsorship does not cover chain 999, so `api/faucet.mjs`
drips 0.002 HYPE once per Privy user — keyed on the identity in the access token rather than on the
address, because an address is free to mint and a faucet keyed on one is empty within the hour. It
signs with a Privy server wallet held under a policy that allows `eth_sendTransaction` on chain 999
up to that amount, denies `CoreWriter` outright, and permits nothing else — so the worst case if
every line of that file is wrong is one drip, on either side of the chain. The policy is `keeper/policy.json`, as Privy returns it, and `test/api/faucet.test.mjs`
asserts what the endpoint refuses.

**Three things have to be true before such a policy means anything, and none is documented.** All
were measured on the live wallet rather than assumed, and each one silently turns the policy into
decoration:

1. **A policy is not enforced until the wallet has an owner.** With `owner_id` null, a rule denying
   *every* method was attached to this wallet and a send still reached the node. The policy needs
   one too, for a different reason: it is enforced without one, but the app secret alone can rewrite
   its rules.
2. **A partial transaction bypasses every condition.** Privy evaluates a policy against the request
   as sent, before it populates anything, so a condition naming a field the request omits resolves
   to nothing and passes. `{to, value}` — the shape Privy's own quickstart shows — leaves `chain_id`
   unresolvable and the chain restriction is a no-op. A rule denying the exact destination address
   did not stop a send until the transaction carried all of its fields, which is why `api/faucet.mjs`
   builds nonce, gas, fees and chain id itself instead of letting Privy fill them in.
3. **A ceiling on `value` is a ceiling in one execution domain, and this wallet has assets in two.**
   A HyperEVM address is also a HyperCore account with its own balances, and `CoreWriter` at
   `0x3333…3333` forwards actions to the exchange for whoever calls it — an `eth_sendTransaction`
   carrying zero value, which every rule written against `value` admits while HyperCore moves the
   money. So the policy denies `to == 0x3333…3333` outright. `to` is the only field that can say it:
   `ethereum_transaction` exposes no `data` and the schema has no `neq`, so *"anywhere but the
   system contract"* is unwriteable and the door has to be named. That DENY is what makes the
   ceiling a bound on what this wallet **holds**, and not only on what it can send on the EVM.

**There are two policy-held wallets here, and the second is the more interesting one.** The faucet
gives a visitor gas; the hedge operator holds `hedgeOperator` on a desk and may call `cover()` and
nothing else, on chain and off it — that is *The operator is a key that can only do this*, above.
The same two findings apply to it and were re-measured on it rather than assumed to have carried
over, and it added a third that this one now has as well: **the policy needs an owner, not just the
wallet.** A policy whose own `owner_id` is null is enforced, but anything holding the app secret can
rewrite its rules — an owned wallet under an unowned policy is a lock with its key hanging beside
it. Both wallets and both policies are owned; `script/faucet-owner.sh` does both in one run and
refuses to rotate a key that is already in use.

With both in place the two secrets are independent: the app secret authenticates the app, the owner
key authorizes the request, and an unsigned send is refused with a 401. `node script/faucet-check.mjs`
re-runs all six cases — the drip, another chain, over the cap, another method, unsigned, and the
`CoreWriter` call — against the live wallet and reports which the policy let through.

**What building on that policy engine actually cost, with the requests and the responses, is
[`FEEDBACK-PRIVY.md`](../FEEDBACK-PRIVY.md).** Six findings, with the requests and the responses. The
one worth the sponsor's time is the sixth, because it is not specific to this chain: a policy whose
conditions are `value` and `chain_id` reads as a spending limit and is one only where the chain's own
gas token is the only thing the key controls. Any system contract that moves assets held under the
same address in another domain — an exchange, a staking module, a bridge — is outside what those two
fields can see, and the schema offers no `neq` with which to exclude a set of them. A policy written
as an allowlist of calls survives that; one written as a ceiling does not, and nothing in the
condition reference tells a reader which shape they are choosing.

The read path has no third party in it. `app/src/abi.js` is a hand-written codec so that nothing
sits between a browser and the calldata going to 1inch's router, and Privy's SDK is vendored rather
than pulled from a CDN and imported only when a visitor asks for a wallet — the book, the desks and
the round trip above are this repository's own code against a node.

It is live before the contracts are: where nothing is deployed, `CorePrecompiles`, `CoreQuote` and
`FloorLens` are planted at throwaway addresses by an `eth_call` state override and the canonical
parameters are priced against the real book. The bytecode is what `forge build` produced and the
node running it is a real one — `./script/probe999.sh` is the same three calls from a shell, and
`results/999_live_quote.md` is what they answered.

**Two layers, and only the demo one is mocked.** The canonical desk trades the real pair — UBTC
`0x9FDBdA0A…3463` against USD₮0 `0xB8CE59FC…5ebb` on 999 — and names `MapOracle`, which has one
updater. The demo desk trades tokens anyone can mint and names `DemoMapOracle`, which anyone can
write, so a visitor can operate the design's one trusted input instead of reading a sentence about
it — and the flow on it is ours: `script/demo-cadence.sh` takes it on a schedule, so that desk's
history is the quote path holding across a week of moving book, not demand anyone brought. Both
price against the same live book.

That split is the trust argument stated as a deployment. The map can only ever *add* a lean, one
below a desk's own floor does nothing, and a stale one is ignored — so the worst a broken keeper can
do is take a lean away. But a desk quoting inside L1 is a desk offering a better price than L1, and
an oracle anyone can write is an oracle anyone can be paid out of. So no desk holding real inventory
points at the open one, and the console says which oracle each desk names.

