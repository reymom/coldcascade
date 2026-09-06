// Proves the faucet's policy is actually enforced, against the live Privy.
//
// A policy on a wallet with no owner is decoration: this exact script, run before
// `script/faucet-owner.sh`, watched a rule that denied *everything* fail to stop a send. So the
// claim in the README is a claim about behaviour, and this is how it is checked rather than
// believed. Every request below must be refused; the wallet holding no funds is not the reason,
// because a policy denial and an empty balance are different errors and this prints which came back.
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
  // The wallet is empty, so anything the policy lets through dies at the node instead. That is the
  // tell: `transaction_broadcast_failure` means the policy allowed it.
  const allowed = res.ok || code === "transaction_broadcast_failure";
  console.log(`${allowed ? "ALLOWED" : "refused"}  ${what}\n          ${code}: ${(out.error ?? "").slice(0, 96)}`);
  return allowed;
}

const send = (chain, value) => ({
  method: "eth_sendTransaction",
  caip2: `eip155:${chain}`,
  params: { transaction: { to: TO, value } },
});

const results = [];
results.push(["a drip on 999, signed", await attempt("the drip itself, on 999, within the cap", send(999, "0x71afd498d0000")), true]);
results.push(["another chain", await attempt("the same drip on ethereum mainnet", send(1, "0x71afd498d0000")), false]);
results.push(["over the cap", await attempt("0.5 HYPE on 999, over the cap", send(999, "0x6f05b59d3b20000")), false]);
results.push(["unsigned", await attempt("the drip with no owner signature", send(999, "0x71afd498d0000"), { sign: false }), false]);
results.push(["another method", await attempt("personal_sign, which the policy never allows",
  { method: "personal_sign", params: { message: "drain me", encoding: "utf-8" } }), false]);

console.log();
let bad = 0;
for (const [name, allowed, want] of results) {
  const ok = allowed === want;
  if (!ok) bad++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name} — ${allowed ? "allowed" : "refused"}, wanted ${want ? "allowed" : "refused"}`);
}
console.log(bad
  ? `\n${bad} wrong. A policy that does not refuse is not a control; check the wallet has an owner_id.`
  : "\nthe policy is enforced: only the drip, only on 999, only signed.");
process.exit(bad ? 1 : 0);
