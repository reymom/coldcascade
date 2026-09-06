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
let state, calls;
const reset = (over = {}) => {
  calls = [];
  state = { metadata: {}, balance: "0x0", linked: [{ type: "wallet", address: ADDR }], sendFails: false, ...over };
};

globalThis.fetch = async (url, init = {}) => {
  calls.push(`${init.method ?? "GET"} ${url}`);
  const ok = (body) => ({ ok: true, json: async () => body });
  if (url.endsWith("/jwks.json")) return ok({ keys: [jwk] });
  if (url.includes("/custom_metadata")) {
    state.metadata = JSON.parse(init.body).custom_metadata;
    return ok({ id: USER, custom_metadata: state.metadata });
  }
  if (url.includes(`/users/${USER}`)) {
    return ok({ id: USER, linked_accounts: state.linked, custom_metadata: state.metadata });
  }
  if (url.includes("/rpc") && url.includes("wallets")) {
    if (state.sendFails) return { ok: false, json: async () => ({ error: "policy denied" }) };
    return ok({ data: { hash: "0xdeadbeef" } });
  }
  if (url.startsWith("https://rpc.hyperliquid")) return ok({ result: state.balance });
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
check("a second request is refused", (await run(post(mint({ sub: USER })))).status, 429);

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
