# Feedback for Privy

Written from putting two server wallets under policies and then trying to *prove* the policies bind.
Everything below was measured against the live API on 2026-09-06, 2026-09-08 and 2026-09-09, with the
request and the response kept. Nothing here is a complaint about the product working: both wallets do what they
are held to. It is about the distance between a policy that is attached and a policy that refuses,
and about one error path that actively misleads whoever tries to measure the difference. Finding 6 is
the one we would most want a vendor to tell us before a customer did.

## What was built

Two Privy server wallets in one app, each under its own policy.

1. **A gas faucet.** A visitor signs in with an email address, receives an embedded wallet, and is
   given 0.002 HYPE on HyperEVM (chain 999) because Privy's sponsorship does not cover that chain.
   The signer is a server wallet allowed `eth_sendTransaction`, on 999, up to the drip.
2. **A hedge operator.** A market-making contract on 999 holds an `operator` address that may call
   one function on itself — `cover()`, which sends a hedge order and can move no funds. The key that
   holds it is a server wallet whose policy allows exactly that call: chain 999, that one contract,
   `value == 0`, calldata decoding to `cover()`. It runs unattended on a five-minute cadence.

The second one is the interesting shape for policies: the *contract* already restricts the key to
one function, and the policy restricts it again to one function on one address. Two independent
controls, neither trusting the other. That is what we wanted to be able to write down, and mostly we
could.

## 1. Policy is bound by the request, so the client must build the whole transaction

A policy is evaluated against the request as sent, before Privy populates a transaction. A condition
naming a field the request omits does not refuse the request. `{to, value}` — the shape the
quickstart shows — leaves `chain_id` unresolvable, and a chain restriction written against it does
not bind.

This is defensible behaviour and it is also the single most expensive thing we learned, because the
failure is silent in the safe-looking direction: the dashboard shows the policy attached, the rules
are right, and the request goes through anyway. Both of our senders now build `chain_id`, `nonce`,
`gas_limit`, `max_fee_per_gas`, `max_priority_fee_per_gas` and `type` themselves.

**The ask:** say it in the quickstart, next to the partial-transaction example, rather than leaving
it to be discovered. One sentence — *"conditions can only judge fields your request actually
carries"* — would have saved us a day across two wallets.

## 2. The transaction fields are three, so "which function" lives somewhere else

`field_source: ethereum_transaction` exposes `to`, `value` and `chain_id`. There is no `data`, and
the API says so by name rather than accepting the condition and never matching it, which we
appreciated:

```
Invalid enum value. Expected 'to' | 'value' | 'chain_id', received 'data'
  at "rules[0].conditions[3].field"                                    (code: invalid_policy_format)
```

So a selector restriction is only expressible through `field_source: ethereum_calldata` with
`function_name` and an `abi` carried on the condition. That works — and it is a nicer thing to read
in a policy than four hex bytes — but it is worth being explicit in the docs that **the ABI on the
condition is the selector guard**, because the natural first attempt is `data starts_with 0x…` and
that attempt fails with an enum error rather than a pointer.

Related, and the reason we noticed: the rule `name` cap is 50 characters and the error arrives
mixed in with real schema errors. Cheap to raise, or to document.

## 3. `neq` does not exist, and `chain_id` takes only `eq` — so "any chain but ours" is unwriteable

DENY beats ALLOW everywhere, which makes a DENY rule the natural way to write a negative. But:

```
Invalid enum value. Expected 'eq' | 'gt' | 'gte' | 'lt' | 'lte' | 'in' | 'in_condition_set'
  | 'contains' | 'starts_with' | 'ends_with', received 'neq'                 (code: invalid_data)

Validation error: Operator 'gt' is not supported for the 'chain_id' field.
  Only 'eq' and 'in' are supported.                              (code: invalid_policy_format)
```

There is no `neq` and no `not_in`, and for `chain_id` there is no ordering either — so **"deny
anything not on chain 999" cannot be written as a rule at all.** Default-deny covers it in practice,
which is why our policies are correct without it. But default-deny is the absence of a rule, and the
absence of a rule is not a thing an auditor can read. The negative rule is what you write when you
want the file to *say* the boundary.

We could write `value > 0x0` as a DENY, because `value` does take ordering; the same intent on
`chain_id` has no expression. **The ask:** `neq` and `not_in` on the fields that already take `in`.

## 4. The one that misleads: gas estimation answers before the policy does

This is the finding we would most like to see changed, because it corrupts the *check* rather than
the control.

An unpopulated request has to be populated, which means its gas is estimated. If the call would
revert, the request comes back as:

```
transaction_broadcast_failure: Execution reverted for an unknown reason. Details: execution reverted
```

That is exactly what a request the policy **allowed** and the node then declined looks like. Any
check script written the obvious way — "`policy_violation` means refused, anything else means the
policy let it through" — reads this as a policy fail-open. Ours did. We spent an hour concluding
that a partial `{to, data: close()}` had escaped the policy, wrote it up as a fail-open, and were
wrong: the estimator had answered first and the policy had never spoken.

The experiment that settled it, in case it is useful to reproduce: attach a temporary DENY rule on
`to` matching our own contract, then send two partial requests to that contract differing only in
calldata — one calling a function that succeeds, one calling a function that reverts for this
sender. The first is refused with `policy_violation`; the second is "allowed". Same rule, same
wallet, same recipient. The only variable is whether the call reverts.

**The asks, in order of how much they would help:**

1. **A dry-run endpoint.** `POST /v1/wallets/{id}/rpc/evaluate` — same body, returns the policy
   decision and the rule id that produced it, and touches no chain. Today the only way to ask a live
   policy a question is to send something and interpret an error, and interpreting that error is
   what this section is about. It would also make policy checks free: ours currently send a nonce
   far ahead of the account so that an allowed request cannot land, which works but is a trick.
2. **A distinct error code** when the failure happened during population or estimation, before
   policy evaluation — `transaction_estimation_failure`, or a `stage` field on the error.
3. **Evaluate the policy before populating.** A request the policy would deny does not need its gas
   estimated.

## 5. Ownership is two things, and only one of them is pressed

A policy is not enforced at all on a wallet whose `owner_id` is null: with no owner, a rule denying
*every* method was attached to our faucet wallet and a send still reached the node. This is
documented behaviour once you know to look for it, and setting an owner is one PATCH.

The half that is easy to miss is that **the policy has an owner of its own**. A policy with
`owner_id: null` *is* enforced — but anything holding the app secret can rewrite its rules, so an
owned wallet under an unowned policy is a lock with its key hanging beside it. Our faucet ran that
way for two days without noticing, and nothing in the API or the dashboard suggested it. Both of
ours are owned now, by the same P-256 key as their wallets.

**The ask:** when a policy with `owner_id: null` is attached to a wallet that has an owner, say so —
in the dashboard, or as a field on the wallet response. It is the one case where the two ownership
settings are visibly inconsistent with each other.

## 6. A `value` cap binds one execution domain, and a wallet can hold assets in two

This is the one we would most want to know before a customer told us, so it is written out in full.

Our faucet policy was a single ALLOW, and its five assertions all passed:

```json
{ "method": "eth_sendTransaction", "action": "ALLOW", "conditions": [
  { "field_source": "ethereum_transaction", "field": "chain_id", "operator": "eq",  "value": "999" },
  { "field_source": "ethereum_transaction", "field": "value",    "operator": "lte", "value": "0x71afd498d0000" }]}
```

Read as English that is *"this key can send at most 0.002 HYPE, on one chain, and nothing else"*, and
on 2026-09-09 that wallet had 0.25 HYPE — about $21, a hundred and twenty-five times the cap —
which the policy could not stop it sending anywhere.

**Why.** HyperEVM (chain 999) and HyperCore, Hyperliquid's exchange, are two execution domains that
share one address space: `0x1BC6…` is an EVM account and a Core account, and they hold separate
balances. A system contract at `0x3333333333333333333333333333333333333333` forwards actions from
the EVM to Core on behalf of `msg.sender`. So this is an ordinary `eth_sendTransaction`:

```
to     0x3333333333333333333333333333333333333333
value  0x0                       <- satisfies `value lte 0x71afd498d0000`
chain  999                       <- satisfies `chain_id eq 999`
data   0x17938e13… (sendRawAction, action 6 `spotSend`, 0.25 HYPE -> the withdrawal address)
```

Every condition passes, because on the EVM nothing of value moves. Core moves the balance. Measured:
two such calls, [`0x0e86ccb6…`][t1] and [`0x2e38826d…`][t2], took 0.01 and then 0.24 HYPE out of that
wallet's Core balance under the policy exactly as written above. (In our case that was the intended
recovery — the funds had arrived on the wrong side and had to be bridged. It worked because the
policy did not stop it, which is the point.)

**The general shape, which is not Hyperliquid-specific.** `value` and `chain_id` describe a transfer
of the chain's own gas token on one chain. They say nothing about what a call *causes* elsewhere, and
"elsewhere" is not hypothetical any more: any chain with a system contract or precompile that moves
assets held under the same address in another domain — an exchange, a staking module, a bridge — has
this shape. A policy that reads as a spending limit is a spending limit on one domain only, and the
docs give a reader no reason to suspect the qualifier.

**What closes it,** and it is worth showing because the schema makes only one form available:

```json
{ "method": "eth_sendTransaction", "action": "DENY", "conditions": [
  { "field_source": "ethereum_transaction", "field": "to", "operator": "eq",
    "value": "0x3333333333333333333333333333333333333333" }]}
```

`to` is the only field that can express it: there is no `data` on `ethereum_transaction` (finding 2)
and no `neq` (finding 3), so *"any target except the system contract"* cannot be written — the rule
has to name the door and DENY it, and rely on DENY beating ALLOW. That works, and our faucet has run
that rule since; `script/faucet-check.mjs` asserts the denial as its sixth case. But it only works
for doors you know about, and enumerating them is the customer's problem under the current schema.

**The asks, in the order we would want them:**

1. **Say what `value` means.** One sentence in the condition reference — *"`value` is the native
   token transferred by this transaction on this chain; it does not bound assets the transaction
   causes to move"* — turns a silent gap into a known one.
2. **A `neq`, or a `not_in`, on `to`.** With it, an allowlist of destinations is one rule and the
   enumeration problem disappears. Without it, every policy that wants "only these addresses" is
   written inside out.
3. Longer term, the thing customers will actually ask for: a way to express *"this key may not
   reach a system contract"* without naming each one, since the set is chain-specific and grows.

Our second wallet was unaffected, and the reason is instructive: the hedge operator's ALLOW names
`to` **and** a decoded `function_name`, so everything that is not that one call on that one contract
was already refused, CoreWriter included — measured, not assumed, as the "Core door" case in
`script/hedge-check.mjs`. **A policy written as an allowlist of calls survived this; a policy written
as a spending limit did not.** That distinction is not visible to someone reading the condition
reference and choosing which shape to write.

[t1]: https://hyperevmscan.io/tx/0x0e86ccb6169e250a98db8ecd590ca12c471c2f94578972981ffe4a9aba52cd46
[t2]: https://hyperevmscan.io/tx/0x2e38826d65d5919f5c096bd088760bc6bcdb09ab49a55d41f4c491204b3179b3

## Reproducing any of this

Two scripts in this repository send these exact requests to the live API and print what came back:

```
node script/faucet-check.mjs   # six cases: the drip, another chain, over the cap, another method,
                              #   unsigned, and CoreWriter — finding 6, now denied
node script/hedge-check.mjs    # thirteen: cover() allowed, and twelve ways of being refused
```

Both are written so that an allowed request cannot land, and both assert the wallet's and the
policy's `owner_id` before anything else. The policies they check are committed as Privy returns
them, in `keeper/policy.json` and `keeper/hedge-policy.json`.
