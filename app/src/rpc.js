// JSON-RPC against HyperEVM nodes: a list of endpoints with failover, a batch transport, and the
// state override that lets the page run contracts the chain has never seen.

/**
 * The endpoints the page reads when `?rpc=` says nothing, in preference order.
 *
 * The official node rate-limits browser traffic without ceremony — HTTP 429, or -32005 on the
 * method — and a page a judge leaves open cannot depend on one URL's mood. The first endpoint
 * that complains is put in cooldown and the next one answers instead. All three serve chain 999;
 * the chain id is asked of whichever answers, never read from this list.
 */
export const DEFAULT_RPCS = [
  "https://rpc.hyperliquid.xyz/evm",
  "https://rpc.hypurrscan.io",
  "https://hyperliquid.drpc.org",
];

/** The canonical endpoint, for callers that name a single URL (the wallet's chain entry). */
export const DEFAULT_RPC = DEFAULT_RPCS[0];

/**
 * What makes a failure worth failing over: the node complaining about *us* (a throttle, a gateway
 * error, an unreachable host), never about the call. A revert or a bad parameter is a real answer
 * and reaches the caller unchanged, from the first endpoint that produced it.
 */
const isThrottle = (status, err) =>
  status === 429 ||
  (status >= 500 && status < 600) ||
  err?.code === -32005 ||
  /rate.?limit|too many|throttl/i.test(err?.message ?? "");

const retryable = (err) =>
  err instanceof TypeError || // fetch could not reach the host at all
  err instanceof SyntaxError || // a 200 that was not JSON is a broken node, not a real answer
  (err instanceof HttpError && isThrottle(err.status)) ||
  (err instanceof RpcError && isThrottle(undefined, err));

class HttpError extends Error {
  constructor(status) {
    super(`HTTP ${status}`);
    this.status = status;
  }
}

/** A node that answers a batch with a single object does not do batches; the calls go one by one. */
class BatchUnsupported extends Error {}

export class RpcError extends Error {
  constructor(method, error) {
    super(`${method}: ${error.message}`);
    this.data = error.data;
    this.code = error.code;
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** A read-only client over a list of endpoints. `overrides` is geth's third eth_call parameter. */
export class Rpc {
  constructor(urls = DEFAULT_RPCS) {
    this.urls = (Array.isArray(urls) ? urls : [urls]).filter(Boolean);
    this.id = 0;
    this.current = 0;
    // Per endpoint: consecutive throttles, and the wall-clock moment it may be tried again.
    this.health = this.urls.map(() => ({ strikes: 0, until: 0 }));
  }

  /** The endpoint currently in favour — the last one that answered. */
  get url() {
    return this.urls[this.current];
  }

  async send(method, params) {
    return this.#run(async (url, nextId) => {
      const res = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: nextId(), method, params }),
      });
      if (!res.ok) throw new HttpError(res.status);
      const body = await res.json();
      if (body.error) throw new RpcError(method, body.error);
      return body.result;
    });
  }

  /**
   * Many calls, one HTTP request, results in the order they were asked for. An entry whose error
   * is a real answer (a revert, bad params) throws exactly as `send` would have thrown it; an
   * entry that is the node complaining fails the whole batch on that endpoint so the cascade
   * re-asks the next one. A node without batch support falls back to one request per call through
   * the same cascade — slower, and said so nowhere, because the results are identical.
   */
  async batch(calls) {
    if (calls.length === 0) return [];
    try {
      return await this.#run(async (url, nextId) => {
        const reqs = calls.map(({ method, params }) => ({ jsonrpc: "2.0", id: nextId(), method, params }));
        const res = await fetch(url, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(reqs),
        });
        if (!res.ok) throw new HttpError(res.status);
        const body = await res.json();
        if (!Array.isArray(body)) {
          if (body?.error && isThrottle(undefined, body.error)) throw new RpcError("batch", body.error);
          throw new BatchUnsupported();
        }
        const byId = new Map(body.map((r) => [r.id, r]));
        return reqs.map((q) => {
          const r = byId.get(q.id);
          if (!r) throw new BatchUnsupported(); // a node that drops entries is not batching honestly
          if (r.error) throw new RpcError(q.method, r.error);
          return r.result;
        });
      });
    } catch (err) {
      if (!(err instanceof BatchUnsupported)) throw err;
      const out = [];
      for (const { method, params } of calls) out.push(await this.send(method, params));
      return out;
    }
  }

  /**
   * The cascade every call goes through. Endpoints are tried in preference order starting at the
   * one that last answered; one that throttles earns an exponential cooldown (5s, 10s, 20s… two
   * minutes) and is skipped until it lapses, so a complaining node is never hammered to be told
   * it is still complaining. If every endpoint is cooling the call waits out the shortest
   * cooldown rather than failing — a judge's tab recovers on its own instead of stranding red
   * text on screen. Errors that are the call's fault propagate on the first endpoint tried.
   */
  async #run(execute) {
    let lastErr = null;
    for (let round = 0; round < 3; round++) {
      let soonest = Infinity;
      for (let k = 0; k < this.urls.length; k++) {
        const i = (this.current + k) % this.urls.length;
        const h = this.health[i];
        const wait = h.until - Date.now();
        if (wait > 0) {
          soonest = Math.min(soonest, wait);
          continue;
        }
        try {
          const result = await execute(this.urls[i], () => ++this.id);
          this.current = i;
          h.strikes = 0;
          return result;
        } catch (err) {
          if (!retryable(err)) throw err;
          lastErr = err;
          h.strikes += 1;
          h.until = Date.now() + Math.min(120_000, 2500 * 2 ** h.strikes);
        }
      }
      if (round < 2) await sleep(soonest === Infinity ? 1500 * (round + 1) : Math.min(soonest, 15_000));
    }
    throw lastErr ?? new Error("every RPC endpoint is cooling down");
  }

  call(tx, overrides, block = "latest") {
    return this.send("eth_call", overrides ? [tx, block, overrides] : [tx, block]);
  }

  async blockNumber() {
    return Number(BigInt(await this.send("eth_blockNumber", [])));
  }

  async chainId() {
    return Number(BigInt(await this.send("eth_chainId", [])));
  }
}

/**
 * Plant contracts at throwaway addresses for the duration of one eth_call.
 *
 * `CoreQuote` takes its reader as a constructor argument, so its runtime code does not exist in any
 * build artifact — the READER immutable is written into it at deployment. An `eth_call` with no
 * `to` executes creation code and returns the runtime it would have deployed, which is the missing
 * step: run the constructor on the node, under an override that already has the reader planted,
 * and keep what comes back.
 *
 * Nothing is deployed and no key signs anything. What runs is the code `forge build` produced,
 * against the book the exchange is running on.
 */
export async function plant(rpc, bytecode, addresses) {
  const overrides = {
    [addresses.corePrecompiles]: { code: bytecode.corePrecompiles },
    [addresses.floorLens]: { code: bytecode.floorLens },
  };
  const runtime = await rpc.call(
    { data: bytecode.coreQuoteCreation + word(addresses.corePrecompiles), gas: "0x2faf080" },
    { [addresses.corePrecompiles]: { code: bytecode.corePrecompiles } },
  );
  overrides[addresses.coreQuote] = { code: runtime };
  return overrides;
}

const word = (address) => address.replace(/^0x/, "").toLowerCase().padStart(64, "0");

/**
 * Poll for a receipt, and treat running out of patience as what it is.
 *
 * Sixty seconds was not enough: a mint sent through an embedded wallet was mined and this gave up
 * before the public RPC served the receipt, which surfaced on screen as "no receipt … after 60s" —
 * indistinguishable from a failure, on a transaction that had in fact succeeded. Three minutes now,
 * with a backoff so a slow node is not hammered, and the thrown error carries the hash so the caller
 * can say *pending* rather than *failed* and offer the explorer.
 */
export async function waitForReceipt(rpc, hash, timeoutMs = 180_000) {
  const deadline = Date.now() + timeoutMs;
  let wait = 1000;
  while (Date.now() < deadline) {
    const receipt = await rpc.send("eth_getTransactionReceipt", [hash]);
    if (receipt) return receipt;
    await new Promise((r) => setTimeout(r, wait));
    wait = Math.min(wait * 1.4, 5000);
  }
  throw Object.assign(
    new Error(`still no receipt after ${Math.round(timeoutMs / 1000)}s — the transaction may yet land`),
    { hash, pending: true },
  );
}
