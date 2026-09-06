// JSON-RPC against a HyperEVM node, and the state override that lets the page run contracts the
// chain has never seen.

export const DEFAULT_RPC = "https://rpc.hyperliquid.xyz/evm";
export const CHAIN_ID = 999;

/**
 * What a wallet needs to be told about a chain it has never seen. Only 999 is a real one; anything
 * else the page is pointed at is a local fork, and a wallet is happy to be handed the generic
 * shape for those.
 */
const CHAIN_METADATA = {
  [CHAIN_ID]: {
    chainName: "HyperEVM",
    nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
    blockExplorerUrls: ["https://hyperevmscan.io"],
  },
};

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

/** The injected wallet, or null. Everything the page writes goes through this and nothing else. */
export function wallet() {
  const provider = globalThis.ethereum;
  if (!provider) return null;
  return {
    provider,
    async accounts() {
      return provider.request({ method: "eth_accounts" });
    },
    async connect() {
      return provider.request({ method: "eth_requestAccounts" });
    },
    async chainId() {
      return Number(BigInt(await provider.request({ method: "eth_chainId" })));
    },
    /**
     * Move the wallet to the chain the page is reading, adding it if the wallet has never seen it.
     *
     * The chain is an argument and not the constant. Everywhere else the page is already
     * chain-agnostic — it takes its addresses from `deployments/<chainid>.json` — and 999 wired
     * into the write path alone meant the Take button was disabled against a local fork of 999,
     * which is the one place the whole taker flow can be rehearsed before there is a mainnet desk.
     */
    async switchTo(chainId, rpcUrl) {
      const hex = "0x" + chainId.toString(16);
      try {
        await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hex }] });
      } catch (err) {
        if (err?.code !== 4902) throw err;
        await provider.request({
          method: "wallet_addEthereumChain",
          params: [{
            chainId: hex,
            chainName: `chain ${chainId}`,
            nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
            ...CHAIN_METADATA[chainId],
            rpcUrls: [rpcUrl],
          }],
        });
      }
    },
    async send(tx) {
      return provider.request({ method: "eth_sendTransaction", params: [tx] });
    },
  };
}

/** Poll for a receipt. Blocks are about a second here, so this is short and not clever. */
export async function waitForReceipt(rpc, hash, timeoutMs = 60_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const receipt = await rpc.send("eth_getTransactionReceipt", [hash]);
    if (receipt) return receipt;
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`no receipt for ${hash} after ${timeoutMs / 1000}s`);
}
