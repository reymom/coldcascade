// The faucet, exercised without Vercel: a fake (req, res), a stubbed Privy and RPC, and a real
// ES256 keypair standing in for Privy's JWKS, so the signature path below is the shipped code and
// not a mock of it.
//
// This is the only server-side thing in the repository and the only path that can send money with
// no human in it, so what it *refuses* is what is worth asserting: a token minted for another app,
// an expired one, one whose signature was edited, an address that is not the signed-in user's, and
// a second request from a user who has already been funded.
//
//   node test/api/faucet.test.mjs
import crypto from "node:crypto";
import handler from "../../api/faucet.mjs";

const APP = "test-app-id";
process.env.PRIVY_APP_ID = APP;
process.env.PRIVY_APP_SECRET = "test-secret";
process.env.PRIVY_FAUCET_WALLET_ID = "test-wallet";

const { publicKey, privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
const jwk = publicKey.export({ format: "jwk" });
jwk.kid = "test-kid"; jwk.alg = "ES256"; jwk.use = "sig";

// The faucet's owner key. The point of it is that the send below carries a signature the policy
// engine can check, so the test verifies that signature the way Privy would.
const owner = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
process.env.PRIVY_AUTHORIZATION_KEY = "wallet-auth:" +
  owner.privateKey.export({ type: "pkcs8", format: "der" }).toString("base64");

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
function mint(claims) {
  const head = b64({ alg: "ES256", typ: "JWT", kid: "test-kid" });
  const body = b64({ iss: "privy.io", aud: APP, exp: Math.floor(Date.now() / 1e3) + 600, ...claims });
  const sig = crypto.sign("sha256", Buffer.from(`${head}.${body}`),
    { key: privateKey, dsaEncoding: "ieee-p1363" });
  return `${head}.${body}.${sig.toString("base64url")}`;
}

const USER = "did:privy:testuser";
const ADDR = "0x1111111111111111111111111111111111111111";
const FAUCET = "0x3333333333333333333333333333333333333333";
let state, calls;
const reset = (over = {}) => {
  calls = [];
  state = { metadata: {}, balance: "0x0", linked: [{ type: "wallet", address: ADDR }], sendFails: false, ...over };
};

globalThis.fetch = async (url, init = {}) => {
  calls.push(`${init.method ?? "GET"} ${url}`);
  const ok = (body) => ({ ok: true, json: async () => body });
  if (url.endsWith("/jwks.json")) {
    if (state.jwksFails) return { ok: false, json: async () => ({ error: "Invalid Privy app id" }) };
    return ok({ keys: [jwk] });
  }
  if (url.includes("/custom_metadata")) {
    state.metadata = JSON.parse(init.body).custom_metadata;
    return ok({ id: USER, custom_metadata: state.metadata });
  }
  if (url.includes(`/users/${USER}`)) {
    return ok({ id: USER, linked_accounts: state.linked, custom_metadata: state.metadata });
  }
  if (/\/wallets\/[^/]+$/.test(url)) return ok({ id: "test-wallet", address: FAUCET });
  if (url.includes("/rpc") && url.includes("wallets")) {
    state.sent = { url, headers: init.headers, body: JSON.parse(init.body) };
    if (state.sendFails) return { ok: false, json: async () => ({ error: "policy denied" }) };
    return ok({ data: { hash: "0xdeadbeef" } });
  }
  if (url.startsWith("https://rpc.hyperliquid")) {
    const { method } = JSON.parse(init.body);
    if (method === "eth_getTransactionCount") return ok({ result: "0x7" });
    if (method === "eth_gasPrice") return ok({ result: "0x5f5e100" });   // 0.1 gwei
    return ok({ result: state.balance });
  }
  throw new Error(`unstubbed ${url}`);
};

const run = async (req) => {
  let out = {};
  const res = { status: (s) => ({ json: (b) => { out = { status: s, body: b }; return out; } }) };
  await handler({ method: "POST", headers: {}, body: {}, ...req }, res);
  return out;
};

const post = (token, body) => ({ headers: { authorization: `Bearer ${token}` }, body: { address: ADDR, chainId: 999, ...body } });
const cases = [];
const check = (name, got, want) => cases.push([name, JSON.stringify(got) === JSON.stringify(want), got, want]);

reset();
check("GET is refused", (await run({ method: "GET" })).status, 405);
check("no token", (await run({ body: { address: ADDR, chainId: 999 } })).status, 401);
check("bad address", (await run(post(mint({ sub: USER }), { address: "nope" }))).status, 400);
check("wrong chain", (await run(post(mint({ sub: USER }), { chainId: 1 }))).status, 400);
check("token for another app", (await run(post(mint({ sub: USER, aud: "someone-else" })))).status, 401);
check("expired token", (await run(post(mint({ sub: USER, exp: 1 })))).status, 401);
check("tampered signature", (await run(post(mint({ sub: USER }).slice(0, -3) + "AAA"))).status, 401);
check("junk that is not a token", (await run(post("aaa.bbb.ccc"))).status, 401);
// A wrong app id in the host's environment must not read as the visitor's token being bad. It did
// once, and cost a session of looking at the token.
// A wrong id is a *different* id, which is also what exercises the per-app JWKS cache.
process.env.PRIVY_APP_ID = "cmtpwj7fs00az0bl4xd6w31z";
reset({ jwksFails: true });
const misconfigured = await run(post(mint({ sub: USER, aud: "cmtpwj7fs00az0bl4xd6w31z" })));
check("a bad app id is a 503, not a 401", misconfigured.status, 503);
check("and it names the variable", (misconfigured.body.error ?? "").includes("PRIVY_APP_ID"), true);
// Padding and quotes survive a paste into a dashboard.
process.env.PRIVY_APP_ID = `  "${APP}" `;
reset();
check("a padded, quoted app id still works", (await run(post(mint({ sub: USER })))).status, 200);
process.env.PRIVY_APP_ID = APP;
reset();
check("and it says so without leaking a parser error",
  (await run(post("aaa.bbb.ccc"))).body.error, "that access token did not verify: malformed");

reset({ linked: [{ type: "wallet", address: "0x2222222222222222222222222222222222222222" }] });
check("address is not the user's", (await run(post(mint({ sub: USER })))).status, 403);

reset({ balance: "0x1" });
check("already has gas", (await run(post(mint({ sub: USER })))).status, 409);

reset({ metadata: { gasFundedAt: "2026-09-06T00:00:00Z" } });
check("already funded once", (await run(post(mint({ sub: USER })))).status, 429);

reset();
const good = await run(post(mint({ sub: USER })));
check("a signed-in user is funded", good, { status: 200, body: { hash: "0xdeadbeef", value: "2000000000000000" } });
check("and the drip is marked on the user", Boolean(state.metadata.gasFundedAt), true);
// Populated in full, and that is a security property rather than a detail: Privy evaluates the
// policy against the request as sent, so a transaction missing `chain_id` is a transaction whose
// chain_id condition passes vacuously. A partial one here means an unenforced policy in production.
check("the drip is 0.002 HYPE to the caller, as a complete transaction",
  state.sent.body.params.transaction, {
    to: ADDR,
    value: "0x71afd498d0000",
    chain_id: 999,
    nonce: 7,
    gas_limit: "0x5208",
    max_fee_per_gas: "0xbebc200",
    max_priority_fee_per_gas: "0x0",
    type: 2,
  });
check("on the chain the policy pins", state.sent.body.caip2, "eip155:999");

// The signature the policy engine checks, verified here the way Privy verifies it: RFC 8785 over
// {version, method, url, body, headers}, SHA-256, P-256. A canonicalizer that drifts would still
// produce a plausible-looking base64 string and every send would be denied in production.
const canonical = (v) =>
  v === null || typeof v !== "object" ? JSON.stringify(v)
  : Array.isArray(v) ? `[${v.map(canonical).join(",")}]`
  : `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}`;
check("and it is signed by the faucet's owner key", crypto.verify(
  "sha256",
  Buffer.from(canonical({
    version: 1, method: "POST", url: state.sent.url, body: state.sent.body,
    headers: { "privy-app-id": APP },
  })),
  owner.publicKey,
  Buffer.from(state.sent.headers["privy-authorization-signature"], "base64"),
), true);

check("a second request is refused", (await run(post(mint({ sub: USER })))).status, 429);

const key = process.env.PRIVY_AUTHORIZATION_KEY;
delete process.env.PRIVY_AUTHORIZATION_KEY;
reset();
check("no owner key means the faucet refuses to run", (await run(post(mint({ sub: USER })))).status, 503);
process.env.PRIVY_AUTHORIZATION_KEY = key;

reset({ sendFails: true });
check("a failed send is a 502", (await run(post(mint({ sub: USER })))).status, 502);
check("and the mark is released", state.metadata.gasFundedAt, "");

let failed = 0;
for (const [name, ok, got, want] of cases) {
  if (!ok) failed++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${ok ? "" : `\n        got ${JSON.stringify(got)} want ${JSON.stringify(want)}`}`);
}
console.log(failed ? `\n${failed} failed` : `\nall ${cases.length} passed`);
process.exit(failed ? 1 : 0);
