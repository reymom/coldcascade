// Gas for a wallet that was minted from an email address, once per person.
//
// A Privy embedded wallet arrives with no HYPE, and Privy's gas sponsorship covers a fixed list of
// chains that does not include this one — so the drip is ours to run. Everything below exists to
// answer two questions before it sends anything: *is this a real signed-in person*, and *have they
// already been given gas*.
//
// **The rate limit is identity, not an address.** An address is free to mint, so a faucet keyed on
// one is empty within the hour. This one is keyed on the Privy user id in the access token, and the
// record that a user was funded is written into that user's own Privy custom metadata — no
// database, and the same account system that proves who they are remembers what they were given.
//
// **The signer is a Privy server wallet under a policy**, not a private key in an environment
// variable. The policy allows `eth_sendTransaction` and nothing else, only on this chain, and only
// up to the drip — so the worst case if everything in this file is wrong is one drip per request,
// on one chain, to somewhere. `keeper/policy.json` in this repo is that policy.
//
// **Two things had to be true before that policy meant anything, and neither is documented.**
// Both were measured on the live wallet by `script/faucet-check.mjs`, which still runs them.
//
//  1. *A policy is not enforced until the wallet has an owner.* With `owner_id: null`, a rule
//     denying every method was attached to this wallet and a send still reached the node. Setting a
//     P-256 owner (`script/faucet-owner.sh`) is what switches enforcement on.
//  2. *A partial transaction bypasses every condition.* Privy evaluates the policy against the
//     request as sent, before it populates anything, so a condition on an absent field resolves to
//     nothing and passes. See `transaction()` below.
//
// With both in place the two secrets are independent: the app secret authenticates the app, the
// owner key authorizes the request, and an unsigned send is refused with a 401. A leak of the
// Vercel environment alone does not move the faucet, and the policy caps what the key itself can
// do — one method, one chain, one ceiling.
//
// Both secrets are Vercel environment variables. Neither is in this repository or in the browser
// bundle, and `.vercelignore` keeps `.env` off the host.

import crypto from "node:crypto";

const AUTH = "https://auth.privy.io/api/v1";
const API = "https://api.privy.io/v1";

/** 0.002 HYPE. A Take is three transactions at ~100k gas and 0.1 gwei — about 0.00004 HYPE — so
 *  this is fifty times over, and the ceiling is what the policy enforces independently of here. */
const DRIP_WEI = 2_000_000_000_000_000n;

const CHAIN_ID = Number(process.env.FAUCET_CHAIN_ID ?? 999);
const RPC_URL = process.env.HYPEREVM_RPC_URL ?? "https://rpc.hyperliquid.xyz/evm";
const MARK = "gasFundedAt";

export default async function handler(req, res) {
  if (req.method !== "POST") return fail(res, 405, "POST only");

  // Trimmed, and quotes stripped: these are pasted into a hosting dashboard by hand, and a value
  // that arrives wrapped or padded fails somewhere far from the paste.
  const appId = env("PRIVY_APP_ID");
  const appSecret = env("PRIVY_APP_SECRET");
  const walletId = env("PRIVY_FAUCET_WALLET_ID");
  // The authorization key is checked here rather than at the send: without it the policy is not
  // enforced, and a faucet whose policy is not enforced should not run at all.
  if (!appId || !appSecret || !walletId || !env("PRIVY_AUTHORIZATION_KEY")) {
    return fail(res, 503, "the faucet is not configured on this deployment");
  }

  const body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body ?? {});
  const address = String(body.address ?? "");
  if (!/^0x[0-9a-fA-F]{40}$/.test(address)) return fail(res, 400, "no address");
  if (Number(body.chainId) !== CHAIN_ID) {
    return fail(res, 400, `the faucet only funds chain ${CHAIN_ID}; this page is on ${body.chainId}`);
  }

  const token = (req.headers.authorization ?? "").replace(/^Bearer /, "");
  if (!token) return fail(res, 401, "sign in first");

  let userId;
  try {
    userId = await verify(token, appId);
  } catch (err) {
    // A configuration fault is not the visitor's token being wrong, and saying so sends whoever is
    // debugging to the wrong place. A one-character truncation of PRIVY_APP_ID in the host's
    // environment once surfaced here as "that access token did not verify".
    if (err.cause === "config") return fail(res, 503, `the faucet is misconfigured: ${err.message}`);
    return fail(res, 401, `that access token did not verify: ${err.message}`);
  }

  const auth = {
    authorization: "Basic " + Buffer.from(`${appId}:${appSecret}`).toString("base64"),
    "privy-app-id": appId,
    "content-type": "application/json",
  };

  const user = await json(`${AUTH}/users/${userId}`, { headers: auth });

  // The address has to be this user's own wallet. Without this the token proves somebody is signed
  // in and says nothing about where the money goes, which is a faucet with an extra step.
  const owns = (user.linked_accounts ?? []).some(
    (a) => typeof a.address === "string" && a.address.toLowerCase() === address.toLowerCase(),
  );
  if (!owns) return fail(res, 403, "that address is not one of this account's wallets");

  if (user.custom_metadata?.[MARK]) {
    return fail(res, 429, "this account has already been given gas once");
  }

  const balance = BigInt(await rpc("eth_getBalance", [address, "latest"]));
  if (balance > 0n) return fail(res, 409, "this wallet already has gas");

  // Claim the drip before sending it. Two requests in flight would otherwise both read an empty
  // balance and both pay; the cost of this order is that a send which fails afterwards has to put
  // the mark back, which it does.
  const claim = (value) =>
    json(`${AUTH}/users/${userId}/custom_metadata`, {
      method: "PATCH",
      headers: auth,
      body: JSON.stringify({ custom_metadata: { ...(user.custom_metadata ?? {}), [MARK]: value } }),
    });
  await claim(new Date().toISOString());

  try {
    const url = `${API}/wallets/${walletId}/rpc`;
    const payload = {
      method: "eth_sendTransaction",
      caip2: `eip155:${CHAIN_ID}`,
      params: { transaction: await transaction(address, walletId, auth) },
    };
    const sent = await json(url, {
      method: "POST",
      headers: { ...auth, "privy-authorization-signature": authorize(url, payload, appId) },
      body: JSON.stringify(payload),
    });
    return res.status(200).json({ hash: sent.data?.hash ?? null, value: DRIP_WEI.toString() });
  } catch (err) {
    await claim("").catch(() => {});
    return fail(res, 502, `the faucet could not send: ${err.message}`);
  }
}

// ---- the transaction, populated here rather than by Privy ----

/**
 * Build the drip as a complete transaction: nonce, gas, fees and chain id included.
 *
 * **This is what makes the policy bind, and it is not optional.** Privy evaluates a policy against
 * the request as sent, before it fills in anything — so a condition on a field the request omits
 * resolves to nothing and passes. Sending `{to, value}` and letting Privy populate the rest, which
 * is the shape its own quickstart shows, means `chain_id` and every other unspecified field are
 * unresolvable and the policy is a no-op: a rule denying this exact `to` address did not stop a
 * send until the transaction below carried all of its fields. Measured both ways.
 *
 * What this costs: the nonce is ours to get right. It is read as `pending` so queued sends count,
 * and two drips racing can still collide — in which case the send fails, the mark is released, and
 * the visitor can press the button again. That is the right way round for a faucet: a collision
 * costs a retry, and the alternative costs the policy.
 */
async function transaction(to, walletId, auth) {
  const from = (await json(`${API}/wallets/${walletId}`, { headers: auth })).address;
  const [nonce, gasPrice] = await Promise.all([
    rpc("eth_getTransactionCount", [from, "pending"]),
    rpc("eth_gasPrice", []),
  ]);
  return {
    to,
    value: "0x" + DRIP_WEI.toString(16),
    chain_id: CHAIN_ID,
    nonce: Number(BigInt(nonce)),
    gas_limit: "0x5208",                                  // 21 000: a plain value transfer
    max_fee_per_gas: "0x" + (BigInt(gasPrice) * 2n).toString(16),
    max_priority_fee_per_gas: "0x0",
    type: 2,
  };
}

// ---- the owner's signature over the request ----

/**
 * Sign a wallet write with the faucet's owner key, which is what makes the policy binding.
 *
 * Privy's scheme: build `{version, method, url, body, headers}`, canonicalize it per RFC 8785, and
 * sign the SHA-256 of that with the P-256 owner key, base64. The canonicalizer is nine lines here
 * rather than a package for the same reason the JWT verifier is: this endpoint is deployed out of a
 * repository whose `package.json` pins 1inch's Solidity graph, and one runtime dependency is one
 * more thing that can re-resolve it. RFC 8785 over this payload is object keys sorted by code unit
 * and `JSON.stringify` for the leaves — there are no floats and no arrays in it.
 *
 * `key` defaults to the faucet's. It is a parameter because there is a second owned wallet in this
 * repository — the hedge operator, whose key signs its `cover()` and nothing else — and the two must
 * not be able to sign for each other; `script/cover.mjs` passes its own.
 */
export function authorize(url, body, appId, ownerKey = env("PRIVY_AUTHORIZATION_KEY")) {
  const pem = ownerKey.replace(/^wallet-auth:/, "");
  if (!pem) throw new Error("no authorization key, so the policy would not be enforced");
  const payload = { version: 1, method: "POST", url, body, headers: { "privy-app-id": appId } };
  const key = crypto.createPrivateKey({
    key: `-----BEGIN PRIVATE KEY-----\n${pem}\n-----END PRIVATE KEY-----`,
    format: "pem",
  });
  return crypto.sign("sha256", Buffer.from(canonical(payload)), key).toString("base64");
}

function canonical(v) {
  if (v === null || typeof v !== "object") return JSON.stringify(v);
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}`;
}

// ---- the access token ----

/**
 * Verify Privy's ES256 access token against the app's own JWKS, and return the user id.
 *
 * Written against `node:crypto` rather than a JWT library because this function is deployed by a
 * static host out of a repository whose `package.json` pins 1inch's Solidity packages: one runtime
 * dependency here is one more thing that can re-resolve that graph. A JWT signature is raw r‖s,
 * which is what `ieee-p1363` means below; the DER default would reject every valid token.
 */
// Keyed by app id, not a bare cache: a warm function that has already fetched one app's keys must
// not keep serving them after the environment is pointed at a different app.
let jwks = { appId: null, doc: null };
async function verify(token, appId) {
  const [h, p, s] = token.split(".");
  if (!h || !p || !s) throw new Error("not a JWT");
  const header = decode(h);
  if (header.alg !== "ES256") throw new Error(`unexpected alg ${header.alg}`);

  // Failing to fetch the app's own keys says nothing about the token: it means this deployment is
  // pointed at an app id that is not ours.
  const keys = async () => {
    try {
      return await json(`${AUTH}/apps/${appId}/jwks.json`);
    } catch (err) {
      throw Object.assign(new Error(`PRIVY_APP_ID is not an app Privy knows (${err.message})`),
        { cause: "config" });
    }
  };

  if (jwks.appId !== appId || !jwks.doc) jwks = { appId, doc: await keys() };
  let jwk = jwks.doc.keys.find((k) => k.kid === header.kid);
  if (!jwk) {
    // Privy rotates keys. One re-fetch, then it is a real failure.
    jwks = { appId, doc: await keys() };
    jwk = jwks.doc.keys.find((k) => k.kid === header.kid);
  }
  if (!jwk) throw new Error("no signing key for this token");

  const ok = crypto.verify(
    "sha256",
    Buffer.from(`${h}.${p}`),
    { key: crypto.createPublicKey({ key: jwk, format: "jwk" }), dsaEncoding: "ieee-p1363" },
    Buffer.from(s, "base64url"),
  );
  if (!ok) throw new Error("bad signature");

  const claims = decode(p);
  if (claims.iss !== "privy.io") throw new Error(`issuer ${claims.iss}`);
  if (claims.aud !== appId) throw new Error("this token was issued for another app");
  if (!claims.exp || claims.exp * 1000 < Date.now()) throw new Error("expired");
  if (!claims.sub) throw new Error("no subject");
  return claims.sub;
}

/** A malformed segment is a malformed token, and should say so rather than surface a parse error. */
function decode(part) {
  try {
    return JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
  } catch {
    throw new Error("malformed");
  }
}

// ---- plumbing ----

async function json(url, init) {
  const res = await fetch(url, init);
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error ?? body.message ?? `HTTP ${res.status}`);
  return body;
}

async function rpc(method, params) {
  const body = await json(RPC_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  if (body.error) throw new Error(body.error.message);
  return body.result;
}

const env = (name) => (process.env[name] ?? "").trim().replace(/^["']|["']$/g, "");

const fail = (res, status, error) => res.status(status).json({ error });
