// The hedge, fired by a key that can do nothing else.
//
// `cover()` reads the desk's spot balance against the square level its owner declared, reads the
// perp position back from HyperCore, and sends an IOC for the difference. It is a second
// transaction by construction — it is not in the taker's swap, because a hedge that cannot fail a
// fill but still bills the taker for it is the taker paying for the maker's private economics. So
// *something* has to send it, and until this file existed that something was the owner, by hand.
//
// This is that sender, and the whole point is what it is not allowed to do. The account names it in
// `hedgeOperator`, which is the only permission it has on chain: `cover` transfers nothing, and
// every call on a `DeskAccount` that can move a token — `withdraw`, `close`, `marginHome`,
// `armHedge` — is `onlyOwner`. Under that, the key itself is a Privy server wallet held by
// `keeper/hedge-policy.json`: one method, one desk, one chain, no value. The ceiling and the
// operator are the owner's signature on a device; this is the trigger inside it. Neither half
// trusts the other, and `script/hedge-check.mjs` is where that is asserted against the live policy
// rather than described.
//
// **It builds the whole transaction rather than letting Privy populate one**, which is not a style
// choice: a policy is evaluated against the request as sent, so a request that omits `chain_id`
// cannot be judged on `chain_id`. The faucet found that; `hedge-check.mjs` re-measured it on this
// wallet. An unpopulated request here would be a policy that reads as a control and is not one.
//
//   node script/cover.mjs             # send only if there is something to cover
//   DRY_RUN=1 node script/cover.mjs   # decide and print, send nothing
//   FORCE=1 node script/cover.mjs     # send even when square, which lands a HedgeSkipped
import fs from "node:fs";
import { authorize } from "../api/faucet.mjs";

const root = new URL("..", import.meta.url);
for (const line of fs.readFileSync(new URL(".env", root), "utf8").split("\n")) {
  const m = /^([A-Z_]+)=(.*)$/.exec(line.trim());
  if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
}
const env = (name) => (process.env[name] ?? "").trim().replace(/^["']|["']$/g, "");

const APP = env("PRIVY_APP_ID");
const SECRET = env("PRIVY_APP_SECRET");
const WALLET = env("PRIVY_HEDGE_WALLET_ID");
const KEY = env("PRIVY_HEDGE_AUTHORIZATION_KEY");
// The cadences do not share an endpoint with the console: one poke a minute already makes us the
// public node's largest single consumer, and a throttled keeper retries where a throttled page
// hangs in front of a judge. The public node stays as the second entry, because a third party that
// goes down must not be able to stop a hedge — and because they fail differently: on this machine
// `fetch` resolves the keeper endpoint to a v6 address that never connects, while `curl` and `cast`
// pick v4 and see nothing wrong. One endpoint would have made that look like a chain outage.
const RPCS = [...new Set([
  env("COVER_RPC_URL") || env("KEEPER_RPC_URL"),
  env("HYPEREVM_RPC_URL") || "https://rpc.hyperliquid.xyz/evm",
].filter(Boolean))];
const CHAIN_ID = Number(env("COVER_CHAIN_ID") || 999);
const at = JSON.parse(fs.readFileSync(new URL("deployments/999.json", root), "utf8"));
const DESK = env("COVER_DESK") || at.operatorDesk;
const COVER = "0xe7d931e4";        // cast sig 'cover()'
const PREVIEW = "0xe65fdbe7";      // cast sig 'coverPreview()'

if (!APP || !SECRET || !WALLET || !KEY) {
  // A missing owner key is not a missing convenience: without it the policy is not enforced at all,
  // and an operator whose policy is not enforced should not run.
  die("set PRIVY_APP_ID, PRIVY_APP_SECRET, PRIVY_HEDGE_WALLET_ID and PRIVY_HEDGE_AUTHORIZATION_KEY" +
      " in .env — ./script/hedge-operator.sh prints all four");
}
if (!DESK) die("no desk: set COVER_DESK, or add operatorDesk to deployments/999.json");

async function rpc(method, params) {
  let last;
  for (const url of RPCS) {
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      });
      const body = await res.json().catch(() => ({}));
      if (body.error) throw new Error(body.error.message);
      return body.result;
    } catch (err) {
      // Kept, never swallowed: a discarded transport error reads downstream exactly like a chain
      // that answered "nothing to do".
      last = new Error(`${method} at ${url}: ${err.message}`);
    }
  }
  throw last;
}

/** `coverPreview()` is the same `HedgeOrder.plan` the transaction would run, so what this prints is
 *  the order that would be sent and not one computed a second way. Four words: two bools, then the
 *  base amount and what it is worth at mark. */
function preview(hex) {
  const w = (i) => BigInt("0x" + hex.slice(2 + i * 64, 66 + i * 64));
  return { wouldCover: w(0) === 1n, isBuy: w(1) === 1n, baseAmount: w(2), notional: w(3) };
}

let p;
try {
  p = preview(await rpc("eth_call", [{ to: DESK, data: PREVIEW }, "latest"]));
} catch (err) {
  log(`FAIL ${DESK}: ${err.message}`);
  die(err.message);
}
const say = (verb) => `${verb} ${DESK}: ${p.wouldCover
  ? `${p.isBuy ? "buy" : "sell"} ${p.baseAmount} base, $${(Number(p.notional) / 1e6).toFixed(2)} at mark`
  : "square — nothing to cover"}`;

if (!p.wouldCover && env("FORCE") !== "1") {
  // Not an error, and not a failure to log: a keeper on a cadence hits this most of the time.
  log(say("SQUARE"));
  process.exit(0);
}
if (env("DRY_RUN") === "1") {
  console.log(say("WOULD COVER"));
  process.exit(0);
}

const from = (await privy(`https://api.privy.io/v1/wallets/${WALLET}`, null)).address;
const [nonce, gasPrice] = await Promise.all([
  rpc("eth_getTransactionCount", [from, "pending"]),
  rpc("eth_gasPrice", []),
]);

const url = `https://api.privy.io/v1/wallets/${WALLET}/rpc`;
const body = {
  method: "eth_sendTransaction",
  caip2: `eip155:${CHAIN_ID}`,
  params: {
    transaction: {
      to: DESK,
      value: "0x0",
      data: COVER,
      chain_id: CHAIN_ID,
      nonce: Number(BigInt(nonce)),
      // A flat cover is 110k; one that reaches CoreWriter and writes the position costs more, and
      // the limit is not what is paid. 300 000 is the ceiling, not the bill.
      gas_limit: "0x493e0",
      max_fee_per_gas: "0x" + (BigInt(gasPrice) * 2n).toString(16),
      max_priority_fee_per_gas: "0x0",
      type: 2,
    },
  },
};

try {
  const sent = await privy(url, body);
  const hash = sent.data?.hash ?? sent.hash ?? null;
  log(`${say("COVER")} · ${hash}`);
  console.log(hash);
} catch (err) {
  // **A receipt is not a fill, and this is where the distinction starts.** Even a landed cover only
  // proves what was sent: HyperCore applies the action seconds later and can reject it without
  // failing the transaction that carried it. What was hedged is read from `0x0800`, never from here.
  log(`FAIL ${DESK}: ${err.message}`);
  die(err.message);
}

async function privy(url, body) {
  const res = await fetch(url, {
    method: body ? "POST" : "GET",
    headers: {
      authorization: "Basic " + Buffer.from(`${APP}:${SECRET}`).toString("base64"),
      "privy-app-id": APP,
      "content-type": "application/json",
      // The owner's signature over this exact request. Two secrets, and neither is sufficient: the
      // app secret authenticates the app, this key authorizes the call, and the policy caps what
      // the key can express.
      ...(body ? { "privy-authorization-signature": authorize(url, body, APP, KEY) } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${out.code ?? res.status}: ${out.error ?? "no body"}`);
  return out;
}

function log(line) {
  const path = env("COVER_LOG") || `${process.env.HOME}/.config/coldcascade/cover.log`;
  try { fs.appendFileSync(path, `${new Date().toISOString()}\t${line}\n`); } catch { /* no log dir */ }
  console.error(line);
}
function die(msg) { console.error(msg); process.exit(1); }
