// Proves the faucet's policy is actually enforced, against the live Privy.
//
// Three things had to be discovered the hard way, and this script is what discovered them. None is
// in Privy's documentation, and each one silently turns the policy into decoration:
//
//   1. A policy on a wallet whose `owner_id` is null is not enforced at all. A rule denying every
//      method was attached to this wallet and a send still reached the node.
//   2. A policy is evaluated against the request *as sent*, before Privy populates a transaction.
//      So `{to, value}` — the shape Privy's own quickstart shows — leaves `chain_id` and the rest
//      unresolvable, every condition passes vacuously, and a rule denying this exact `to` address
//      does not stop the send. The faucet therefore builds the whole transaction itself.
//   3. A cap on `value` caps one execution domain, and this wallet has assets in two. HyperEVM and
//      HyperCore share an address, and CoreWriter is reachable by an ordinary `eth_sendTransaction`
//      whose `value` is zero — so a policy the first five cases below certify as enforced still let
//      0.25 HYPE leave HyperCore on 2026-09-09. The sixth case is that call, now denied.
//
// So the claim in the README is a claim about behaviour, and this is how it is checked rather than
// believed. The wallet holding no funds is not what refuses anything here: a policy denial and an
// empty balance are different errors, and this prints which one came back.
//
//   node script/faucet-check.mjs
import fs from "node:fs";
import { authorize } from "../api/faucet.mjs";

for (const line of fs.readFileSync(new URL("../.env", import.meta.url), "utf8").split("\n")) {
  const m = /^([A-Z_]+)=(.*)$/.exec(line.trim());
  if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
}
const { PRIVY_APP_ID: APP, PRIVY_APP_SECRET: SECRET, PRIVY_FAUCET_WALLET_ID: WALLET } = process.env;
if (!APP || !SECRET || !WALLET) throw new Error("set PRIVY_APP_ID, PRIVY_APP_SECRET and PRIVY_FAUCET_WALLET_ID in .env");
if (!process.env.PRIVY_AUTHORIZATION_KEY) {
  console.error("PRIVY_AUTHORIZATION_KEY is unset — run ./script/faucet-owner.sh first and put its\n" +
    "output in .env. Until the wallet has an owner the policy is not enforced at all, which is\n" +
    "the state this script exists to detect.");
  process.exit(1);
}

const url = `https://api.privy.io/v1/wallets/${WALLET}/rpc`;
const TO = "0x000000000000000000000000000000000000dEaD";
const DRIP = "0x71afd498d0000";    // 0.002 HYPE, the ceiling in keeper/policy.json
const OVER = "0x6f05b59d3b20000";  // 0.5 HYPE

/**
 * `CoreWriter.sendRawAction` carrying action 6, `spotSend` — the call that empties this wallet's
 * *HyperCore* balance while satisfying every condition the value cap is made of.
 *
 * This is the sixth case because the first five were all true and the wallet was still drainable.
 * A HyperEVM address and a HyperCore account are the same address, and CoreWriter at 0x3333…3333
 * is the door between them: `eth_sendTransaction`, chain 999, `value: 0` — under the cap, because
 * nothing of value moves *on the EVM* — and HyperCore moves the spot balance. The 0.002 HYPE
 * ceiling was never a ceiling on what the wallet holds, only on what it can send in one domain.
 * Measured on 2026-09-09: 0.25 HYPE left this wallet's Core balance in two such calls
 * (0x0e86ccb6…, 0x2e38826d…) under the policy exactly as the first five cases describe it.
 *
 * The rule that closes it names `to`, because it is the only field that can: `field_source:
 * ethereum_transaction` exposes `to`, `value` and `chain_id` and nothing else — there is no `data`
 * — and there is no `neq`, so "any target except CoreWriter" is not writable. Naming CoreWriter in
 * a DENY is the way round, and DENY beats ALLOW. It is enough because CoreWriter acts for its
 * caller: reaching it through an intermediary contract would move *that contract's* Core balance,
 * not this wallet's, so this address calling it directly is the whole of the exposure.
 *
 * The amount below is dust, and deliberately not the 0.24 that moved. The rule keys on `to`, so
 * the amount is not what is under test, and a check that would be catastrophic if the stale nonce
 * ever stopped working is a check written the wrong way round.
 */
const CORE_WRITER = "0x3333333333333333333333333333333333333333";
const SPOT_SEND = "0x17938e13" + w("20") + w("64") +          // sendRawAction(bytes), 100 bytes
  "01000006" +                                                 // version 1, action 6 spotSend
  w("2222222222222222222222222222222222222222") +              // HYPE's system address, the
  w("96") +                                                    //   documented exception to 0x20‖index
  w("2710") + "0".repeat(56);                                  // 0.0001 HYPE at Core weiDecimals 8

/** Left-pad to a 32-byte word. Nine characters, so the calldata above can be read rather than trusted. */
function w(hex) { return hex.padStart(64, "0"); }

async function attempt(what, body, { sign = true } = {}) {
  const res = await fetch(url, {
    method: "POST",
    headers: {
      authorization: "Basic " + Buffer.from(`${APP}:${SECRET}`).toString("base64"),
      "privy-app-id": APP,
      "content-type": "application/json",
      ...(sign ? { "privy-authorization-signature": authorize(url, body, APP) } : {}),
    },
    body: JSON.stringify(body),
  });
  const out = await res.json().catch(() => ({}));
  const code = out.code ?? (res.ok ? "ok" : `http_${res.status}`);
  // Anything the policy lets through dies at the node on the nonce instead of landing. That is the
  // tell, and it is the reason this is safe to run: `policy_violation` means the policy refused,
  // `transaction_broadcast_failure` means it allowed the request and the node declined to broadcast.
  const allowed = res.ok || code === "transaction_broadcast_failure";
  console.log(`${allowed ? "ALLOWED" : "refused"}  ${what}\n          ${code}: ${(out.error ?? "").slice(0, 92)}`);
  return allowed;
}

/**
 * The shape the faucet actually sends. Populated, because a partial one is not policed.
 *
 * The nonce is deliberately far ahead of the wallet's, so that a request the policy *allows* still
 * cannot land: HyperEVM's RPC rejects any nonce ahead of the account's current state rather than
 * queueing it (the same behaviour that forced `--slow` on the deploy). The policy has already
 * decided by the time the node sees it, which is the only thing this script is asking about — and a
 * check that costs 0.002 HYPE every time it runs is a check nobody runs. An earlier version of this
 * file did spend, once.
 */
const STALE_NONCE = 900_000_000;
const full = (over = {}) => ({
  to: TO, value: DRIP, chain_id: 999, nonce: STALE_NONCE, gas_limit: "0x5208",
  max_fee_per_gas: "0x5f5e100", max_priority_fee_per_gas: "0x0", type: 2, ...over,
});
const send = (tx, caip2 = "eip155:999") =>
  ({ method: "eth_sendTransaction", caip2, params: { transaction: tx } });

const results = [
  ["the drip itself", await attempt("the drip, on 999, within the cap", send(full())), true],
  ["another chain", await attempt("the same drip on ethereum mainnet",
    send(full({ chain_id: 1 }), "eip155:1")), false],
  ["over the cap", await attempt("0.5 HYPE on 999, over the cap", send(full({ value: OVER }))), false],
  ["another method", await attempt("personal_sign, which the policy never allows",
    { method: "personal_sign", params: { message: "drain me", encoding: "utf-8" } }), false],
  // Two secrets, and this is the one that proves it: the app secret authenticates the app, the
  // owner key authorizes the request, and a leak of the Vercel environment alone does not send.
  // (An earlier version of this script saw an unsigned *partial* transaction go through, which is
  // the same fail-open as the conditions — one more reason the faucet sends a populated one.)
  ["unsigned", await attempt("the drip with no owner signature", send(full()), { sign: false }), false],
  // Sixth, and the only one that was ever ALLOWED here: see SPOT_SEND above. `value` is zero and
  // the chain is right, so the cap and the chain rule both pass — the DENY on `to` is what refuses
  // it, and this line is the assertion that the DENY is attached and not merely written down.
  ["the Core door", await attempt("spotSend through CoreWriter, which drains HyperCore",
    send(full({ to: CORE_WRITER, value: "0x0", data: SPOT_SEND, gas_limit: "0x1d4c0" }))), false],
];

console.log();
let bad = 0;
for (const [name, allowed, want] of results) {
  const ok = allowed === want;
  if (!ok) bad++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name} — ${allowed ? "allowed" : "refused"}, wanted ${want ? "allowed" : "refused"}`);
}
console.log(bad
  ? `\n${bad} wrong. A policy that does not refuse is not a control. Check the wallet has an owner_id,\n` +
    "and that the transaction above carries every field the conditions name."
  : "\nthe policy is enforced: only eth_sendTransaction, only on 999, only up to 0.002 HYPE,\n" +
    "only signed by the owner key, and not through CoreWriter — so the cap binds what this\n" +
    "wallet holds on HyperCore too, not only what it holds on the EVM.");
process.exit(bad ? 1 : 0);
