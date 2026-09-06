// Whatever can send a transaction on the chain the page is reading.
//
// Two of them: the browser's injected wallet, and a Privy embedded wallet a visitor gets by typing
// an email address. Both are reduced to the same five members, so the Take and Map buttons are
// written once and neither knows which one it is holding.
//
// **The chain is a constructor argument, and that is the point.** An earlier version of the write
// path compared the wallet's chain against a `CHAIN_ID = 999` constant while every read came from
// `deployments/<chainid>.json`, so Take was dead against a local fork — the one place the taker
// flow can be rehearsed before there is a mainnet desk. The fix is structural rather than a
// corrected comparison: a signer is *built for* a chain, that chain comes from the `eth_chainId`
// the page connected to, and there is no chain id written anywhere below this line. For the Privy
// client the same fact is enforced by Privy itself — it is constructed with `supportedChains` of
// length one, so the embedded wallet has no other chain it could be on.

import { waitForReceipt } from "./rpc.js";

/**
 * What a wallet has to be told about a chain it has never seen.
 *
 * One description, two consumers: `wallet_addEthereumChain` for an injected wallet and Privy's
 * `supportedChains`. They want the same fields under different names, and writing it twice is how
 * they drift. Only 999 has a real identity here; anything else the page is pointed at is a fork of
 * it, and the generic shape is both true and enough.
 */
const KNOWN = {
  999: {
    name: "HyperEVM",
    nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
    explorer: { name: "HyperEVMScan", url: "https://hyperevmscan.io" },
  },
};

export function chainFor(chainId, rpcUrl) {
  const known = KNOWN[chainId];
  return {
    id: chainId,
    name: known?.name ?? `chain ${chainId}`,
    nativeCurrency: known?.nativeCurrency ?? { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
    blockExplorers: known?.explorer ? { default: known.explorer } : undefined,
  };
}

/** `hyperevmscan.io/tx/…`, or nothing when the chain has no explorer — a fork has none. */
export const explorerTx = (chain, hash) =>
  chain.blockExplorers ? `${chain.blockExplorers.default.url}/tx/${hash}` : null;

// ---- the injected wallet ----

/**
 * MetaMask, Rabby, or whatever else put an EIP-1193 provider on the page. Unchanged behaviour: it
 * may be on any chain, so it is asked to move to this signer's chain and added if it has never
 * seen it.
 */
export function injected(chain) {
  const provider = globalThis.ethereum;
  if (!provider) return null;

  const self = {
    kind: "injected",
    chain,
    address: null,
    label: "injected wallet",

    async connect() {
      const [address] = await provider.request({ method: "eth_requestAccounts" });
      self.address = address ?? null;
      await self.switchToChain();
      return self;
    },

    /** The account it is already on, without a prompt. Null when the page has never been allowed. */
    async resume() {
      const [address] = await provider.request({ method: "eth_accounts" });
      self.address = address ?? null;
      return address ? self : null;
    },

    async onChain() {
      const id = Number(BigInt(await provider.request({ method: "eth_chainId" })));
      return id === chain.id;
    },

    async switchToChain() {
      const hex = "0x" + chain.id.toString(16);
      try {
        await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hex }] });
      } catch (err) {
        if (err?.code !== 4902) throw err;
        await provider.request({
          method: "wallet_addEthereumChain",
          params: [{
            chainId: hex,
            chainName: chain.name,
            nativeCurrency: chain.nativeCurrency,
            rpcUrls: chain.rpcUrls.default.http,
            blockExplorerUrls: chain.blockExplorers ? [chain.blockExplorers.default.url] : [],
          }],
        });
      }
    },

    send(tx) {
      return provider.request({ method: "eth_sendTransaction", params: [tx] });
    },

    /** Gas is the visitor's own problem here; only an embedded wallet gets a drip. */
    async fund() { return null; },

    onChanged(fn) {
      provider.on?.("accountsChanged", fn);
      provider.on?.("chainChanged", fn);
    },

    async disconnect() { self.address = null; },
  };
  return self;
}

// ---- Privy ----

/**
 * The SDK, loaded the first time somebody asks for a wallet and never before.
 *
 * 836 kB of somebody else's JavaScript is a real cost and the Floor does not pay it: the book, the
 * desks and the round trip are this repository's own code against a node, and a visitor who only
 * reads the screen never fetches this file. It arrives when a taker wants a key.
 */
let sdk = null;
const loadSdk = async () => (sdk ??= await import("../vendor/privy.js"));

export async function privyConfig(base = ".") {
  const res = await fetch(`${base}/privy.json`);
  if (!res.ok) throw new Error(`privy.json: HTTP ${res.status}`);
  const config = await res.json();
  return config.appId ? config : null;
}

/**
 * Open a Privy session for one chain.
 *
 * The iframe is Privy's secure context: the key material lives inside it, on Privy's origin, and
 * this page talks to it by `postMessage` and never sees a private key. Nothing here is reachable
 * until it has loaded, so the load is awaited rather than raced.
 */
export async function openPrivy(chain, config) {
  const { Privy, LocalStorage, getUserEmbeddedEthereumWallet, getEntropyDetailsFromUser } =
    await loadSdk();

  const privy = new Privy({
    appId: config.appId,
    ...(config.clientId ? { clientId: config.clientId } : {}),
    storage: new LocalStorage(),
    // One chain, and it is the one the page read. `supportedChains` overrides Privy's default list
    // and an embedded wallet defaults to the first entry, so the wallet cannot be anywhere else —
    // which is the bug from the injected path made unrepresentable rather than re-checked.
    supportedChains: [chain],
  });
  await privy.initialize();

  const iframe = document.createElement("iframe");
  iframe.title = "Privy secure context";
  iframe.style.cssText = "position:absolute;width:0;height:0;border:0;visibility:hidden";
  const loaded = new Promise((resolve, reject) => {
    iframe.addEventListener("load", resolve, { once: true });
    iframe.addEventListener("error", () => reject(new Error("the Privy iframe failed to load")), { once: true });
  });
  iframe.src = privy.embeddedWallet.getURL();
  document.body.append(iframe);
  privy.setMessagePoster(iframe.contentWindow);
  window.addEventListener("message", (event) => {
    if (event.source !== iframe.contentWindow) return;
    privy.embeddedWallet.onMessage(event.data);
  });
  await loaded;

  /** A logged-in user becomes a signer: find the embedded wallet, make one if there is none. */
  const signerFor = async (user) => {
    let account = getUserEmbeddedEthereumWallet(user);
    let current = user;
    if (!account) {
      current = (await privy.embeddedWallet.create({})).user;
      account = getUserEmbeddedEthereumWallet(current);
    }
    if (!account) throw new Error("Privy returned no embedded Ethereum wallet");
    const { entropyId, entropyIdVerifier } = getEntropyDetailsFromUser(current);
    const provider = await privy.embeddedWallet.getEthereumProvider({
      wallet: account, entropyId, entropyIdVerifier,
    });
    return wrap(privy, provider, chain, account.address, current);
  };

  return {
    /** Whoever is already signed in on this device, or null. Survives a reload. */
    async resume() {
      try {
        const { user } = await privy.user.get();
        return user ? await signerFor(user) : null;
      } catch {
        return null;
      }
    },
    sendCode: (email) => privy.auth.email.sendCode(email),
    async submitCode(email, code) {
      const { user } = await privy.auth.email.loginWithCode(email, code);
      return signerFor(user);
    },
  };
}

function wrap(privy, provider, chain, address, user) {
  const email = user?.linked_accounts?.find((a) => a.type === "email")?.address;
  const self = {
    kind: "privy",
    chain,
    address,
    label: email ?? "embedded wallet",

    async connect() { return self; },
    async resume() { return self; },
    // Structural, not optimistic: the client was built with this one chain as its only supported
    // chain, so there is no state in which the embedded wallet is somewhere else.
    async onChain() { return true; },
    async switchToChain() {},

    send(tx) {
      return provider.request({ method: "eth_sendTransaction", params: [{ ...tx, chainId: chain.id }] });
    },

    /**
     * Ask the faucet for gas, once, and only if this wallet has none.
     *
     * A wallet minted from an email address holds no HYPE, and Privy's gas sponsorship covers a
     * fixed list of chains that does not include this one — so the drip is ours to run. The request
     * carries this user's Privy access token and the server drips per *Privy user*, not per
     * address: identity is the whole rate limit, since an address is free to mint and a faucet
     * keyed on one is empty within the hour.
     */
    async fund(rpc) {
      const balance = BigInt(await rpc.send("eth_getBalance", [address, "latest"]));
      if (balance > 0n) return null;
      const token = await privy.getAccessToken();
      if (!token) throw new Error("not signed in");
      const res = await fetch("/api/faucet", {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
        body: JSON.stringify({ address, chainId: chain.id }),
      });
      const body = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(body.error ?? `faucet: HTTP ${res.status}`);
      if (body.hash) await waitForReceipt(rpc, body.hash);
      return body.hash ?? null;
    },

    onChanged() {},
    async disconnect() { await privy.auth.logout(); },
  };
  return self;
}
