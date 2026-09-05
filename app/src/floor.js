// The Floor: the live book, the desks quoting against it, and the two buttons that do something.

import {
  Rpc, plant, loadSelectors, readFloor, readOrder, takerTraits, quoteCall, swapCall,
  erc20, mapUpdate, paramsTuple, decode, calldata,
} from "./chain.js";
import { wallet, waitForReceipt, DEFAULT_RPC, CHAIN_ID } from "./rpc.js";
import { drawStrip } from "./bands.js";
import { roundTrip, bestRoundTrip } from "./arb.js";

const POLL_MS = 2000;

/** Where the simulated contracts are planted. Any address with no code will do. */
const SIMULATED = {
  corePrecompiles: "0x00000000000000000000000000000000c01dca5c",
  coreQuote: "0x00000000000000000000000000000000c01dca5d",
  floorLens: "0x00000000000000000000000000000000c01dca5e",
};

/**
 * The canonical parameters, as a desk with no account behind it.
 *
 * This is what the Floor draws before Monday's deploy: `FloorLens` prices a parameter set exactly
 * as it prices a deployed desk, because the quote is a pure function of the book and the
 * parameters. Once `deployments/999.json` exists the page reads the real accounts instead and this
 * row disappears.
 */
const CANONICAL_PREVIEW = {
  base: "0x0000000000000000000000000000000000000000",
  quote: "0x0000000000000000000000000000000000000000",
  perpIndex: 0,
  pxNum: 1n, pxDen: 1000n,      // BTC szDecimals 5, on UBTC(8) against USDT0(6)
  quietBps: 20, leanBps: 15, stressBps: 25,
  mapOracle: "0x0000000000000000000000000000000000000000",
  mapMaxAge: 300,
  mapMinNotional: 5_000_000n,
  minBase: 0n,
  maxBase: (1n << 128n) - 1n,
};

export async function mountFloor(root) {
  const ui = build(root);
  const rpcUrl = new URLSearchParams(location.search).get("rpc") ?? DEFAULT_RPC;
  const rpc = new Rpc(rpcUrl);

  let state;
  try {
    state = await connectToChain(rpc, rpcUrl);
  } catch (err) {
    ui.status.className = "status error";
    ui.status.textContent = `Could not reach ${rpcUrl}.\n\n${err.message}`;
    return;
  }
  ui.status.remove();
  ui.page.hidden = false;

  const view = { state, rpc, ui, floor: null, account: null, chainOk: false };
  wireTake(view);
  wireMap(view);
  wireWallet(view);

  const tick = async () => {
    try {
      view.floor = await readFloor(rpc, {
        lens: state.addresses.floorLens,
        coreQuote: state.addresses.coreQuote,
        perpIndex: 0,
        accounts: state.accounts,
        previews: state.previews.map(paramsTuple),
        overrides: state.overrides,
        sel: state.sel,
      });
      render(view);
      ui.error.hidden = true;
    } catch (err) {
      ui.error.hidden = false;
      ui.error.textContent = `read failed: ${err.message}`;
    }
  };
  await tick();
  setInterval(tick, POLL_MS);
}

/**
 * Two modes, and the page says which on screen.
 *
 * **deployed** — `deployments/999.json` exists, so the addresses are real and the desks are
 * accounts holding tokens. **simulated** — nothing is deployed yet, so the reader, the quote and
 * the lens are planted at throwaway addresses by a state override and the canonical parameters are
 * priced with no account behind them. The book is the live one in both.
 */
async function connectToChain(rpc, rpcUrl) {
  const [chainId, sel, bytecode] = await Promise.all([rpc.chainId(), loadSelectors(), fetchJson("./bytecode.json")]);
  const deployment = await fetchJson(`../deployments/${chainId}.json`).catch(() => null);

  if (deployment?.floorLens && deployment?.coreQuote) {
    return {
      mode: "deployed",
      chainId, rpcUrl, sel, deployment,
      addresses: deployment,
      accounts: [deployment.canonicalDesk, deployment.demoDesk].filter(Boolean),
      previews: [],
      overrides: null,
    };
  }
  return {
    mode: "simulated",
    chainId, rpcUrl, sel, deployment: null,
    addresses: SIMULATED,
    accounts: [],
    previews: [CANONICAL_PREVIEW],
    overrides: await plant(rpc, bytecode, SIMULATED),
  };
}

const fetchJson = async (url) => {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return res.json();
};

// ---- render ----

function render(view) {
  const { floor, ui, state } = view;
  const { book, bookOk, desks } = floor;

  ui.mode.textContent = state.mode === "deployed"
    ? `live · lens ${short(state.addresses.floorLens)}`
    : "simulated · nothing is deployed yet";
  ui.mode.className = `chip chip-${state.mode}`;
  ui.meta.textContent =
    `chain ${floor.chainId} · block ${floor.blockNumber.toLocaleString("en-US")}` +
    (floor.l1Block ? ` · L1 ${floor.l1Block.toLocaleString("en-US")}` : "") +
    ` · ${new Date().toLocaleTimeString("en-US", { hour12: false })}`;

  if (!bookOk) {
    ui.book.textContent = "the book could not be read";
    ui.regime.textContent = "";
    return;
  }
  const dislocation = Number(book.oracle) === 0 ? 0
    : Number((BigInt(book.oracle) - BigInt(book.mark)) * 10_000n / BigInt(book.oracle));

  ui.book.replaceChildren(
    stat("bid", px(book.bid)), stat("ask", px(book.ask)),
    stat("mark", px(book.mark)), stat("oracle", px(book.oracle)),
    stat("oracle − mark", `${dislocation > 0 ? "+" : ""}${dislocation} bps`),
  );

  const best = bestRoundTrip(book, desks);
  renderArb(view, best);
  renderRegime(view, desks, best);

  drawStrip(ui.strip, book, desks);
  renderTable(view, desks, book);
  renderPanels(view, desks);
}

/**
 * The number the whole page is about.
 *
 * It is one subtraction on two prices out of the same `eth_call`, and the reason it is worth a
 * headline is that it does not need a cascade to be true. `app/src/arb.js` has the arithmetic and
 * `test/Inarbitrable.t.sol` has the same round trip asserted against the contract, fuzzed.
 */
function renderArb(view, best) {
  const { ui } = view;
  if (!best) {
    ui.arb.replaceChildren(div("arb-caption",
      "No desk on this screen has a price right now, so there is nothing to arbitrage and nothing "
      + "to claim. An empty field here means a read failed, not that a number was zero."));
    return;
  }

  const { desk, trip } = best;
  // The compact name: the panel says "canonical" four times, and the mode chip above it already
  // says whether anything is deployed.
  const who = desk.label && desk.label.length ? desk.label : desk.account === ZERO ? "canonical" : short(desk.account);
  const open = trip.best > 0;
  const atTheTouch = !open && trip.best > -0.5;

  const caption = div("arb-caption");
  if (open) {
    caption.innerHTML =
      `<b>${escape(who)}</b> can be taken and closed at L1 for a profit right now. That is not `
      + `supposed to be reachable — every leg of the quote is clamped to L1's own crossing price — `
      + `so read it as a book that moved between two reads, or as a bug on this screen. It is not `
      + `an invitation.`;
  } else if (atTheTouch) {
    caption.innerHTML =
      `<b>${escape(who)}</b> is leaning. Its absorbing side has walked the whole way to L1's own `
      + `price and stopped on it: a better fill than L1 for whoever is being forced out, and still `
      + `exactly nothing for an arbitrageur. Zero is the tightest this can ever be.`;
  } else {
    caption.innerHTML =
      `The best round trip available against any desk on this screen, and it is against `
      + `<b>${escape(who)}</b>. Nothing here can be bought and sold back to L1 for a profit — not `
      + `because the desk is wide, but because it has no earlier price to be wrong about.`;
  }

  const legs = div("arb-legs");
  legs.append(
    leg(`buy from ${who} at ${px(trip.prices.deskAsk)}, sell into L1's bid ${px(trip.prices.bid)}`,
      `${bpsText(trip.buyFromDesk)} bps`),
    leg(`sell to ${who} at ${px(trip.prices.deskBid)}, buy back at L1's ask ${px(trip.prices.ask)}`,
      `${bpsText(trip.sellToDesk)} bps`),
    leg("L1's own spread, which either exit has to cross", `${trip.l1SpreadBps.toFixed(2)} bps`, true),
  );

  ui.arb.replaceChildren(
    div(`arb-value ${open ? "arb-open" : "arb-safe"}`, `${bpsText(trip.best)} bps`),
    caption,
    legs,
  );
}

/** What regime the floor is in, said as what it proves rather than as what is happening. */
function renderRegime(view, desks, best) {
  const leaning = desks.filter((d) => d.lean !== 0);
  const { ui } = view;

  if (leaning.length === 0) {
    ui.regime.textContent =
      "QUIET — every desk is outside L1 on both sides. This is the regime the page is here to show:"
      + " nothing is happening, and the round trip above is still under water.";
    ui.regime.className = "regime";
    return;
  }
  ui.regime.textContent =
    `LEANING — ${leaning.map((d) => `${name(d)} on the ${d.lean === 1 ? "bid" : "ask"}`).join(", ")}`
    + ". The absorbing side is inside L1 and capped at L1's own price; the same round trip is now"
    + " zero rather than negative, which is as good as it is ever allowed to get.";
  ui.regime.className = "regime regime-lean";
}

function renderTable(view, desks, book) {
  const rows = desks.map((d) => {
    const trip = roundTrip(book, d);
    const tr = document.createElement("tr");
    const band = d.quoted
      ? `−${d.params.quietBps} / +${d.params.quietBps} bps`
      : "—";
    const quote = d.quoted ? `${px(d.bidPx)} / ${px(d.askPx)}` : "no price";
    const inventory = d.account === ZERO
      ? "—"
      : `${amount(d.baseBalance, 8)} base · ${amount(d.quoteBalance, 6)} quote`;
    const map = d.params.mapOracle === ZERO
      ? "book-only"
      : (view.state.deployment && sameAddress(d.params.mapOracle, view.state.deployment.demoMapOracle)
          ? "open — anyone posts"
          : "one updater");
    const hedge = d.account === ZERO ? "—"
      : d.hedgeArmed ? (d.coverBase > 0n ? `armed, ${amount(d.coverBase, 8)} to cover` : "armed, flat")
      : "off";

    for (const [text, cls] of [
      [name(d), "name"], [band, ""], [quote, "num"],
      [trip ? `${bpsText(trip.best)} bps` : "—", trip && trip.best > 0 ? "lean-1" : ""],
      [inventory, ""], [map, ""], [hedge, ""],
      [d.lean === 0 ? "—" : d.lean === 1 ? "bid" : "ask", `lean-${d.lean}`],
    ]) {
      const td = document.createElement("td");
      td.className = cls;
      td.textContent = text;
      tr.append(td);
    }
    return tr;
  });
  view.ui.rows.replaceChildren(...rows);
}

// ---- the two buttons ----

function renderPanels(view, desks) {
  const takeable = desks.filter((d) => d.account !== ZERO && d.open);
  fillSelect(view.ui.takeDesk, takeable);
  fillSelect(view.ui.mapDesk, desks.filter((d) => d.params.mapOracle !== ZERO && d.account !== ZERO));

  const none = takeable.length === 0;
  view.ui.takeNote.textContent = none
    ? "No desk is deployed yet. The Floor is quoting the canonical parameters against the live book; Take turns on when the desks are on chain."
    : "One swap through the official SwapVM router on 999. The page reads the order back from the account rather than rebuilding it.";
  view.ui.takeGo.disabled = none || !view.chainOk;

  const mapNone = view.ui.mapDesk.options.length === 0;
  view.ui.mapNote.textContent = mapNone
    ? "No desk with a map oracle is deployed yet."
    : "";
}

function fillSelect(select, desks) {
  const previous = select.value;
  select.replaceChildren(...desks.map((d) => {
    const option = document.createElement("option");
    option.value = d.account;
    option.textContent = name(d);
    return option;
  }));
  if (desks.some((d) => d.account === previous)) select.value = previous;
}

function wireTake(view) {
  const { ui } = view;
  ui.takeGo.addEventListener("click", async () => {
    const desk = view.floor.desks.find((d) => d.account === ui.takeDesk.value);
    if (!desk) return;
    const sellBase = ui.takeSide.value === "sell";
    const [tokenIn, tokenOut] = sellBase ? [desk.params.base, desk.params.quote] : [desk.params.quote, desk.params.base];
    const decimalsIn = sellBase ? 8 : 6;
    const amountIn = units(ui.takeAmount.value, decimalsIn);
    if (amountIn <= 0n) return say(ui.takeOut, "enter an amount", true);

    const { rpc, state } = view;
    const w = wallet();
    if (!w) return say(ui.takeOut, "no wallet in this browser", true);

    try {
      ui.takeGo.disabled = true;
      const [account] = await w.connect();
      await w.switchToHyperEvm(state.rpcUrl);

      const order = await readOrder(rpc, state.sel, desk.account);
      const traits = takerTraits({ isExactIn: true, minOut: 0n });
      const quoted = await rpc.call({
        from: account,
        to: state.addresses.router,
        data: quoteCall(state.sel, order, tokenIn, tokenOut, amountIn, traits),
      });
      const [amountInQ, amountOut] = decode(["uint256", "uint256", "bytes32"], quoted);

      // What crossing L1 would give, so the number has something to be compared to.
      const crossing = sellBase
        ? amountIn * BigInt(view.floor.book.bid) * desk.params.pxNum / desk.params.pxDen
        : amountIn * desk.params.pxDen / (BigInt(view.floor.book.ask) * desk.params.pxNum);
      const edge = crossing === 0n ? 0 : Number((amountOut - crossing) * 10_000n / crossing);
      say(ui.takeOut,
        `quote: ${amount(amountOut, sellBase ? 6 : 8)} out for ${amount(amountInQ, decimalsIn)} in — ` +
        `${edge >= 0 ? "+" : ""}${edge} bps against crossing L1. sending…`);

      await ensureAllowance(view, w, account, tokenIn, state.addresses.router, amountInQ, desk);
      const hash = await w.send({
        from: account,
        to: state.addresses.router,
        data: swapCall(state.sel, order, tokenIn, tokenOut, amountIn, traits),
      });
      say(ui.takeOut, `sent ${short(hash)} — waiting`);
      const receipt = await waitForReceipt(rpc, hash);
      say(ui.takeOut,
        receipt.status === "0x1"
          ? `filled. ${amount(amountOut, sellBase ? 6 : 8)} out, ${short(hash)}`
          : `reverted, ${short(hash)}`,
        receipt.status !== "0x1");
    } catch (err) {
      say(ui.takeOut, err.message ?? String(err), true);
    } finally {
      ui.takeGo.disabled = false;
    }
  });
}

/** Mint the mock leg if the taker has none, then approve the router. Both are the demo layer. */
async function ensureAllowance(view, w, account, token, spender, needed, desk) {
  const { rpc, state } = view;
  const balance = BigInt(await rpc.call({ to: token, data: erc20.balanceOf(state.sel, account) }));
  if (balance < needed && isDemoToken(state, token)) {
    const hash = await w.send({ from: account, to: token, data: erc20.mint(state.sel, account, needed - balance) });
    await waitForReceipt(rpc, hash);
  }
  const allowance = BigInt(await rpc.call({ to: token, data: erc20.allowance(state.sel, account, spender) }));
  if (allowance >= needed) return;
  const hash = await w.send({ from: account, to: token, data: erc20.approve(state.sel, spender, needed) });
  await waitForReceipt(rpc, hash);
}

const isDemoToken = (state, token) =>
  state.deployment && [state.deployment.demoBase, state.deployment.demoQuote].some((t) => sameAddress(t, token));

/**
 * The map poke, labelled as what it is.
 *
 * The map is the one input the design takes on trust: it is reconstructed off chain, it can only
 * ever *add* a lean, and a stale one is ignored. This button writes one. On the demo desk anybody
 * can, because that desk points at `DemoMapOracle`; on the canonical desk only the updater can, and
 * the page says so rather than hiding the button.
 */
function wireMap(view) {
  const { ui } = view;
  ui.mapGo.addEventListener("click", async () => {
    const desk = view.floor.desks.find((d) => d.account === ui.mapDesk.value);
    if (!desk) return;
    const w = wallet();
    if (!w) return say(ui.mapOut, "no wallet in this browser", true);
    try {
      ui.mapGo.disabled = true;
      const [account] = await w.connect();
      await w.switchToHyperEvm(view.state.rpcUrl);
      const below = units(ui.mapNotional.value, 0) * (ui.mapSide.value === "below" ? 1n : 0n);
      const above = units(ui.mapNotional.value, 0) * (ui.mapSide.value === "above" ? 1n : 0n);
      const hash = await w.send({
        from: account,
        to: desk.params.mapOracle,
        data: mapUpdate(view.state.sel, desk.params.perpIndex, below, above),
      });
      say(ui.mapOut, `posted ${short(hash)} — the lean shows on the next tick and expires in ${desk.params.mapMaxAge}s`);
      await waitForReceipt(view.rpc, hash);
    } catch (err) {
      say(ui.mapOut, err.message ?? String(err), true);
    } finally {
      ui.mapGo.disabled = false;
    }
  });
}

function wireWallet(view) {
  const w = wallet();
  if (!w) {
    view.ui.connect.textContent = "no wallet in this browser";
    view.ui.connect.disabled = true;
    return;
  }
  const refresh = async () => {
    const [account] = await w.accounts();
    view.account = account ?? null;
    view.chainOk = account ? (await w.chainId()) === CHAIN_ID : false;
    view.ui.connect.textContent = account ? short(account) : "connect a wallet";
  };
  view.ui.connect.addEventListener("click", async () => {
    await w.connect();
    await w.switchToHyperEvm(view.state.rpcUrl);
    await refresh();
  });
  w.provider.on?.("accountsChanged", refresh);
  w.provider.on?.("chainChanged", refresh);
  refresh();
}

// ---- helpers ----

const ZERO = "0x0000000000000000000000000000000000000000";
const sameAddress = (a, b) => (a ?? "").toLowerCase() === (b ?? "").toLowerCase();
const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const name = (d) => (d.label && d.label.length ? d.label : d.account === ZERO ? "canonical (parameters only)" : short(d.account));

/** Raw HyperCore price to dollars: raw / 10^(6 - szDecimals), and BTC's szDecimals is 5. */
const px = (raw) => `$${(Number(raw) / 10).toLocaleString("en-US", { minimumFractionDigits: 1, maximumFractionDigits: 1 })}`;

const amount = (v, decimals) => {
  const n = Number(v) / 10 ** decimals;
  return n.toLocaleString("en-US", { maximumFractionDigits: decimals > 6 ? 6 : 2 });
};

const units = (text, decimals) => {
  const n = Number(text);
  if (!Number.isFinite(n) || n < 0) return 0n;
  return BigInt(Math.round(n * 10 ** decimals));
};

/** A signed bps figure. "−0.00" is a lie about a positive number, so the sign follows the value. */
const bpsText = (v) => `${v > 0 ? "+" : v < 0 ? "\u2212" : ""}${Math.abs(v).toFixed(2)}`;

const escape = (s) => s.replace(/[<>&]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;" })[c]);

function div(cls, text) {
  const node = document.createElement("div");
  node.className = cls;
  if (text !== undefined) node.textContent = text;
  return node;
}

function leg(label, value, muted = false) {
  const row = document.createElement("div");
  row.className = "arb-leg";
  const k = div("arb-leg-k", label);
  const v = div(`arb-leg-v${muted ? " arb-muted" : ""}`, value);
  row.append(k, v);
  return row;
}

function stat(label, value) {
  const div = document.createElement("div");
  div.className = "stat";
  const k = document.createElement("div");
  k.className = "stat-label";
  k.textContent = label;
  const v = document.createElement("div");
  v.className = "stat-value";
  v.textContent = value;
  div.append(k, v);
  return div;
}

function say(node, text, isError = false) {
  node.textContent = text;
  node.className = isError ? "out out-error" : "out";
}

function build(root) {
  const id = (name) => root.querySelector(`#${name}`);
  return {
    status: id("floor-status"), page: id("floor-page"), error: id("floor-error"),
    mode: id("floor-mode"), meta: id("floor-meta"),
    book: id("floor-book"), arb: id("floor-arb"), regime: id("floor-regime"), strip: id("floor-strip"),
    rows: id("floor-rows"), connect: id("floor-connect"),
    takeDesk: id("take-desk"), takeSide: id("take-side"), takeAmount: id("take-amount"),
    takeGo: id("take-go"), takeOut: id("take-out"), takeNote: id("take-note"),
    mapDesk: id("map-desk"), mapSide: id("map-side"), mapNotional: id("map-notional"),
    mapGo: id("map-go"), mapOut: id("map-out"), mapNote: id("map-note"),
  };
}
