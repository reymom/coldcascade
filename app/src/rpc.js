// JSON-RPC against a HyperEVM node, and the state override that lets the page run contracts the
// chain has never seen.

// The default the page reads when `?rpc=` says nothing. It is a URL and not a chain id: what chain
// this is gets asked of the node with `eth_chainId`, and every address and every signer follows
// that answer. There is no chain constant in this file.
export const DEFAULT_RPC = "https://rpc.hyperliquid.xyz/evm";

/** A read-only client. `overrides` is geth's third eth_call parameter. */
export class Rpc {
  constructor(url = DEFAULT_RPC) {
    this.url = url;
    this.id = 0;
  }

  async send(method, params) {
    const res = await fetch(this.url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++this.id, method, params }),
    });
    if (!res.ok) throw new Error(`${method}: HTTP ${res.status}`);
    const body = await res.json();
    if (body.error) throw new RpcError(method, body.error);
    return body.result;
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

export class RpcError extends Error {
  constructor(method, error) {
    super(`${method}: ${error.message}`);
    this.data = error.data;
    this.code = error.code;
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
