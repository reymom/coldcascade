// Proves the hedge operator's policy is enforced, against the live Privy.
//
// `hedgeOperator` on a `DeskAccount` is a key that may call `cover()` and, by the contract, nothing
// else: `cover` transfers nothing and every other entry point is `onlyOwner`. The policy behind this
// wallet narrows that again, to one function on one desk on one chain with no value attached — so
// the operator is not "trusted less than the owner", it is a key that cannot express any other
// action. That is a claim about behaviour, and this is where it is checked rather than believed.
//
// It re-tests the faucet's two findings on this wallet rather than assuming they carried over, and
// they are properties of Privy rather than of the faucet: a policy on a wallet with `owner_id: null`
// is not enforced at all, and a policy is evaluated against the request *as sent*, so a request
// Privy has to populate is judged only on the fields it carries. This wallet adds a third, which is
// the faucet's own gap: **the policy has an owner too.** A policy with `owner_id: null` can be
// rewritten by anything holding the app secret, so an unowned policy on an owned wallet is a lock
// with its key beside it. Both are the same P-256 key here, and the last line of this script says
// which — a run that prints no owner has found the state it exists to detect.
//
// Nothing here spends: every populated request carries a nonce far ahead of the wallet's, so a
// request the policy *allows* still cannot land — HyperEVM rejects a nonce ahead of the account
// rather than queueing it. `policy_violation` means the policy refused; `transaction_broadcast_
// failure` means it allowed the request and the node declined it, which is the pass for the one
// case that should be allowed.
//
//   node script/hedge-check.mjs
import fs from "node:fs";
import { authorize } from "../api/faucet.mjs";

for (const line of fs.readFileSync(new URL("../.env", import.meta.url), "utf8").split("\n")) {
  const m = /^([A-Z_]+)=(.*)$/.exec(line.trim());
  if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
}
const {
  PRIVY_APP_ID: APP, PRIVY_APP_SECRET: SECRET,
  PRIVY_HEDGE_WALLET_ID: WALLET, PRIVY_HEDGE_AUTHORIZATION_KEY: KEY, PRIVY_HEDGE_OPERATOR: OPERATOR,
} = process.env;
if (!APP || !SECRET || !WALLET) {
  throw new Error("set PRIVY_APP_ID, PRIVY_APP_SECRET and PRIVY_HEDGE_WALLET_ID in .env — ./script/hedge-operator.sh prints them");
}
if (!KEY) {
  console.error("PRIVY_HEDGE_AUTHORIZATION_KEY is unset. Until the wallet has an owner its policy is\n" +
    "not enforced at all, which is the state this script exists to detect. Run ./script/hedge-operator.sh.");
  process.exit(1);
}

const at = JSON.parse(fs.readFileSync(new URL("../deployments/999.json", import.meta.url), "utf8"));
const DESK = at.operatorDesk;      // the one desk the policy names
const OTHER = at.hedgedDesk;       // a desk of ours that it does not
const UBTC = "0x9FDBdA0A5e284c32744D2f17Ee5c74B284993463";
const DEAD = "0x000000000000000000000000000000000000dEaD";

// Calldata, hand-built: `cast sig` for the selectors, then 32-byte words. A helper here would be a
// dependency, and the arguments below are the only ones this file ever needs.
const word = (v) => BigInt(v).toString(16).padStart(64, "0");
const addr = (a) => a.toLowerCase().replace(/^0x/, "").padStart(64, "0");
const COVER = "0xe7d931e4";                                              // cover()
const CLOSE = "0x43d726d6";                                              // close()
const ARM = `0x6c18b037${word(1)}${word(20_000_000)}${addr(OPERATOR ?? DEAD)}${word(30)}`;
const XFER = `0xa9059cbb${addr(DEAD)}${word(1)}`;                        // transfer(address,uint256)

const basic = {
  authorization: "Basic " + Buffer.from(`${APP}:${SECRET}`).toString("base64"),
  "privy-app-id": APP,
  "content-type": "application/json",
};

/**
 * Both halves of the first finding, asked of Privy rather than assumed.
 *
 * A wallet with `owner_id: null` does not enforce its policy at all — a rule denying every method
 * was attached to the faucet's wallet in that state and a send still reached the node. A *policy*
 * with `owner_id: null` is enforced, but anything holding the app secret can rewrite it, which is
 * the same hole one level up. Neither is visible from a denial: a policy that is not enforced and a
 * policy with no rule for the request both look like whatever the request happened to do.
 */
async function owned(what, path) {
  const out = await (await fetch(`https://api.privy.io/v1${path}`, { headers: basic })).json();
  const id = out.owner_id ?? null;
  console.log(`${id ? "owned  " : "UNOWNED"}  ${what}\n          owner_id: ${id ?? "null — the app secret alone is full authority"}`);
  return Boolean(id);
}

const url = `https://api.privy.io/v1/wallets/${WALLET}/rpc`;
async function attempt(what, body, { sign = true } = {}) {
  const res = await fetch(url, {
    method: "POST",
    headers: {
      ...basic,
      ...(sign ? { "privy-authorization-signature": authorize(url, body, APP, KEY) } : {}),
    },
    body: JSON.stringify(body),
  });
  const out = await res.json().catch(() => ({}));
  const code = out.code ?? (res.ok ? "ok" : `http_${res.status}`);
  const allowed = res.ok || code === "transaction_broadcast_failure";
  console.log(`${allowed ? "ALLOWED" : "refused"}  ${what}\n          ${code}: ${(out.error ?? "").slice(0, 92)}`);
  return allowed;
}

/**
 * The shape the cadence actually sends: every field populated, for the reason the faucet found the
 * hard way. A request that omits `chain_id` cannot be judged on `chain_id`, and Privy resolves an
 * absent field to nothing and passes it — so `script/cover.mjs` builds the whole transaction and so
 * does every case below that expects to be judged on one.
 */
const STALE_NONCE = 900_000_000;
const full = (over = {}) => ({
  to: DESK, value: "0x0", data: COVER, chain_id: 999, nonce: STALE_NONCE, gas_limit: "0x30d40",
  max_fee_per_gas: "0x5f5e100", max_priority_fee_per_gas: "0x0", type: 2, ...over,
});
const send = (tx, caip2 = "eip155:999") =>
  ({ method: "eth_sendTransaction", caip2, params: { transaction: tx } });

const results = [
  ["the wallet has an owner", await owned("the wallet, without which no policy is enforced",
    `/wallets/${WALLET}`), true],
  ["the policy has an owner", await owned("the policy, without which the app secret can rewrite it",
    `/policies/${process.env.PRIVY_HEDGE_POLICY_ID}`), true],

  ["cover, the one thing it is for",
    await attempt("cover() on the operator desk, on 999, value 0", send(full())), true],

  // The four the operator must not be able to express. `close()` and `armHedge` share the desk, the
  // chain and the value with the allowed call and differ only in the four selector bytes, which is
  // the sharpest form of the question: the policy has to be reading the calldata, not the envelope.
  ["another desk",
    await attempt("cover() on the hedged desk, which the policy does not name",
      send(full({ to: OTHER }))), false],
  ["close()",
    await attempt("close(), which returns the desk's inventory to the owner",
      send(full({ data: CLOSE }))), false],
  ["armHedge()",
    await attempt("armHedge(), which is the operator rewriting its own ceiling",
      send(full({ data: ARM }))), false],
  ["a token transfer",
    await attempt("transfer() of UBTC, the plain theft case",
      send(full({ to: UBTC, data: XFER }))), false],
  ["personal_sign",
    await attempt("personal_sign, which the policy never allows",
      { method: "personal_sign", params: { message: "drain me", encoding: "utf-8" } }), false],

  // The envelope, for completeness: same call, wrong chain, and any native value at all.
  ["another chain",
    await attempt("the same cover() on ethereum mainnet", send(full({ chain_id: 1 }), "eip155:1")), false],
  ["any value at all",
    await attempt("cover() with 1 wei attached", send(full({ value: "0x1" }))), false],

  // Two secrets, and this is what proves they are independent: the app secret authenticates the
  // app, the owner key authorizes the request. A leak of one environment does not fire a hedge.
  ["unsigned",
    await attempt("cover() with no owner signature", send(full()), { sign: false }), false],

  // The faucet's second finding, re-measured here rather than assumed to have carried over: a
  // request Privy still has to populate is judged only on the fields it actually carries. Measured
  // on this wallet: `to` and the calldata do bind, `chain_id` and `value` do not — a partial
  // `{to, data}` naming this desk and this function is allowed, and one naming any other address is
  // refused. So the residue of the fail-open is a request that must already be the call this key
  // exists to make, and `script/cover.mjs` populates everything anyway.
  //
  // **The calldata here is `cover()` and not `close()` on purpose.** An unpopulated request has its
  // gas estimated, and calldata the desk would revert on fails that estimate — which comes back as
  // `transaction_broadcast_failure` before the policy has said anything at all, and reads in this
  // script exactly like a policy that allowed it. A check that asks a policy question with
  // reverting calldata gets an answer from the node instead, and cannot tell.
  ["a partial transaction",
    await attempt("cover() at another address, with nothing else filled in",
      send({ to: DEAD, data: COVER })), false],
];

console.log();
let bad = 0;
for (const [name, allowed, want] of results) {
  const ok = allowed === want;
  if (!ok) bad++;
  const [yes, no] = name.endsWith("an owner") ? ["owned", "unowned"] : ["allowed", "refused"];
  console.log(`${ok ? "PASS" : "FAIL"}  ${name} — ${allowed ? yes : no}, wanted ${want ? yes : no}`);
}
console.log(bad
  ? `\n${bad} wrong. A policy that does not refuse is not a control. Check the wallet and the policy\n` +
    "both have an owner, and that the transaction above carries every field the conditions name."
  : `\nthe policy is enforced: ${DESK} only, cover() only, chain 999 only, value 0 only,\n` +
    "and only signed by the operator's own key. Everything else is a policy_violation.");
process.exit(bad ? 1 : 0);
