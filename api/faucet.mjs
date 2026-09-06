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
// on one chain, to somewhere. `keeper/policy.json` in this repo is that policy, and it is enforced
// by Privy rather than by the code below.
//
// The app secret is a Vercel environment variable. It is not in this repository, it is not in the
// browser bundle, and `.vercelignore` keeps `.env` off the host.

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

  const appId = process.env.PRIVY_APP_ID;
  const appSecret = process.env.PRIVY_APP_SECRET;
  const walletId = process.env.PRIVY_FAUCET_WALLET_ID;
  if (!appId || !appSecret || !walletId) {
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
    const sent = await json(`${API}/wallets/${walletId}/rpc`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({
        method: "eth_sendTransaction",
        caip2: `eip155:${CHAIN_ID}`,
        params: { transaction: { to: address, value: "0x" + DRIP_WEI.toString(16) } },
      }),
    });
    return res.status(200).json({ hash: sent.data?.hash ?? null, value: DRIP_WEI.toString() });
  } catch (err) {
    await claim("").catch(() => {});
    return fail(res, 502, `the faucet could not send: ${err.message}`);
  }
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
let jwks = null;
async function verify(token, appId) {
  const [h, p, s] = token.split(".");
  if (!h || !p || !s) throw new Error("not a JWT");
  const header = decode(h);
  if (header.alg !== "ES256") throw new Error(`unexpected alg ${header.alg}`);

  jwks ??= await json(`${AUTH}/apps/${appId}/jwks.json`);
  let jwk = jwks.keys.find((k) => k.kid === header.kid);
  if (!jwk) {
    // Privy rotates keys. One re-fetch, then it is a real failure.
    jwks = await json(`${AUTH}/apps/${appId}/jwks.json`);
    jwk = jwks.keys.find((k) => k.kid === header.kid);
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

const decode = (part) => JSON.parse(Buffer.from(part, "base64url").toString("utf8"));

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

const fail = (res, status, error) => res.status(status).json({ error });
