// The Floor: the live book, the desks quoting against it, and the two buttons that do something.

import {
  Rpc, plant, loadSelectors, readFloor, readOrder, takerTraits, quoteCall, swapCall,
  erc20, mapUpdate, paramsTuple, decode, calldata,
} from "./chain.js";
import { waitForReceipt, DEFAULT_RPC } from "./rpc.js";
import { chainFor, explorerTx, injected, openPrivy, privyConfig } from "./signer.js";
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

  const view = { state, rpc, ui, floor: null, signer: null };
  wireTake(view);
  wireMap(view);
  wireSignIn(view);

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
  // Everything downstream — the addresses, the injected wallet, the Privy client — hangs off this
  // one answer from the node. Nothing below reads a chain id from anywhere else.
  const chain = chainFor(chainId, rpcUrl);
  const privy = await privyConfig().catch(() => null);

  if (deployment?.floorLens && deployment?.coreQuote) {
    return {
      mode: "deployed",
      chainId, rpcUrl, chain, privy, sel, deployment,
      addresses: deployment,
      accounts: [deployment.canonicalDesk, deployment.demoDesk].filter(Boolean),
      previews: [],
      overrides: null,
    };
  }
  return {
    mode: "simulated",
    chainId, rpcUrl, chain, privy, sel, deployment: null,
    addresses: SIMULATED,
    accounts: [],
    previews: [CANONICAL_PREVIEW],
    overrides: await plant(rpc, bytecode, SIMULATED),
  };
}

/// `no-store`, and not as a precaution.
///
/// These three files — the address book, the selectors and the bytecode — are exactly the ones that
/// change when contracts are redeployed, and they are the ones a browser is happiest to keep. A
/// stale address book is the worst failure this page has: it reads as "read failed" against an
/// address that has no code, which looks like a broken chain rather than a cached file, and it
/// costs an hour to find. `replay.js` already does this for the CSV for the same reason.
const fetchJson = async (url) => {
  const res = await fetch(url, { cache: "no-store" });
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
  // Default to a desk whose tokens a visitor can actually get. The canonical desk trades the real
  // pair, so a taker arriving with an empty wallet cannot fill against it — and it was first in the
  // list, which made "press the button" revert for exactly the person the page is built for.
  fillSelect(view.ui.takeDesk, takeable, takeable.find((d) => isDemoToken(view.state, d.params.base)));
  fillSelect(view.ui.mapDesk, desks.filter((d) => d.params.mapOracle !== ZERO && d.account !== ZERO));

  const none = takeable.length === 0;
  const chosen = takeable.find((d) => d.account === view.ui.takeDesk.value);
  const mintable = chosen && isDemoToken(view.state, chosen.params.base);
  view.ui.takeNote.textContent = none
    ? "No desk is deployed yet. The Floor is quoting the canonical parameters against the live book; Take turns on when the desks are on chain."
    : !view.signer
      ? `One swap through the official SwapVM router on chain ${view.state.chainId}. Sign in above — an email address is enough, and the wallet that appears is the one that signs it.`
      : mintable
        ? `Three transactions on chain ${view.state.chainId}: mint the demo token, approve the router, swap. The last goes through the official SwapVM router, and the page reads the order back from the account rather than rebuilding it. Selling base is where the bound bites — the desk's bid is clamped to L1's own.`
        : `This desk trades the real pair, so the page cannot mint your side of it: bring your own ${chosen ? short(chosen.params.base) : "tokens"} and approve the router. The demo desk above takes mintable tokens and costs nothing.`;
  view.ui.takeGo.disabled = none || !view.signer;

  const mapNone = view.ui.mapDesk.options.length === 0;
  view.ui.mapNote.textContent = mapNone
    ? "No desk with a map oracle is deployed yet."
    : "";
}

function fillSelect(select, desks, preferred) {
  const previous = select.value;
  select.replaceChildren(...desks.map((d) => {
    const option = document.createElement("option");
    option.value = d.account;
    option.textContent = name(d);
    return option;
  }));
  if (desks.some((d) => d.account === previous)) select.value = previous;
  else if (preferred) select.value = preferred.account;
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
    const signer = view.signer;
    if (!signer) return say(ui.takeOut, "sign in first — an email address is enough", true);

    try {
      ui.takeGo.disabled = true;
      const account = signer.address;
      await signer.switchToChain();

      // An embedded wallet minted from an email address holds no gas. Ask for the drip before the
      // first of the three transactions rather than after the first one fails: a judge who watches
      // "insufficient funds" scroll past has already decided what this is.
      //
      // Say so *first*. The faucet calls Privy and then waits for the drip's receipt, which is ten
      // seconds of nothing on screen — long enough that the first person to use this reloaded the
      // page in the middle of it. Every step below announces itself before it blocks, not after.
      say(ui.takeOut, "checking this wallet for gas…");
      const funded = await signer.fund(rpc);
      say(ui.takeOut, funded
        ? `funded this wallet with gas — ${short(funded)}. reading the desk's order…`
        : "reading the desk's order…");

      const order = await readOrder(rpc, state.sel, desk.account);
      say(ui.takeOut, "pricing it against the live book…");
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
        `${edge >= 0 ? "+" : ""}${edge} bps against crossing L1. three transactions from here; ` +
        `each waits for its receipt, so give it a moment and do not reload.`);

      await ensureAllowance(view, signer, tokenIn, state.addresses.router, amountInQ, ui.takeOut);
      say(ui.takeOut, "swapping through the official router — 3 of 3");
      const hash = await signer.send({
        from: account,
        to: state.addresses.router,
        data: swapCall(state.sel, order, tokenIn, tokenOut, amountIn, traits),
      });
      say(ui.takeOut, `swap sent ${short(hash)} — waiting`);
      const receipt = await waitForReceipt(rpc, hash);
      const link = explorerTx(state.chain, hash);
      say(ui.takeOut,
        receipt.status === "0x1"
          ? `filled. ${amount(amountOut, sellBase ? 6 : 8)} out, ${short(hash)}`
          : `reverted, ${short(hash)}`,
        receipt.status !== "0x1",
        link);
    } catch (err) {
      // A transaction the page stopped waiting for has not failed, and saying so as an error is how
      // somebody reloads in the middle of a working flow. Every step here is resumable — the mint
      // is skipped once the balance is there, the approve once the allowance is — so the honest
      // message is what is true and what to do about it.
      if (err.pending) {
        say(ui.takeOut,
          `${short(err.hash)} was sent and is still pending — this page stopped waiting, it did not `
          + `fail. Check the explorer, then press the button again: whatever landed is skipped.`,
          false, explorerTx(state.chain, err.hash));
      } else {
        say(ui.takeOut, err.message ?? String(err), true);
      }
    } finally {
      ui.takeGo.disabled = false;
    }
  });
}

/**
 * Mint the mock leg if the taker has none, then approve the router. Both are the demo layer, and
 * both are said out loud: three transactions is what taking a desk costs, and a flow that hides two
 * of them behind a spinner is a flow a judge cannot check.
 */
async function ensureAllowance(view, signer, token, spender, needed, out) {
  const { rpc, state } = view;
  const account = signer.address;
  const balance = BigInt(await rpc.call({ to: token, data: erc20.balanceOf(state.sel, account) }));
  if (balance < needed && isDemoToken(state, token)) {
    say(out, "minting the demo token — 1 of 3");
    const hash = await signer.send({ from: account, to: token, data: erc20.mint(state.sel, account, needed - balance) });
    await waitForReceipt(rpc, hash);
  }
  const allowance = BigInt(await rpc.call({ to: token, data: erc20.allowance(state.sel, account, spender) }));
  if (allowance >= needed) return;
  say(out, "approving the router — 2 of 3");
  const hash = await signer.send({ from: account, to: token, data: erc20.approve(state.sel, spender, needed) });
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
    const signer = view.signer;
    if (!signer) return say(ui.mapOut, "sign in first — an email address is enough", true);
    try {
      ui.mapGo.disabled = true;
      const account = signer.address;
      await signer.switchToChain();
      await signer.fund(view.rpc);
      const below = units(ui.mapNotional.value, 0) * (ui.mapSide.value === "below" ? 1n : 0n);
      const above = units(ui.mapNotional.value, 0) * (ui.mapSide.value === "above" ? 1n : 0n);
      const hash = await signer.send({
        from: account,
        to: desk.params.mapOracle,
        data: mapUpdate(view.state.sel, desk.params.perpIndex, below, above),
      });
      say(ui.mapOut, `posted ${short(hash)} — the lean shows on the next tick and expires in ${desk.params.mapMaxAge}s`);
      await waitForReceipt(view.rpc, hash);
    } catch (err) {
      // Same rule as Take: giving up on a receipt is not the write failing, and the map is visible
      // on the next tick either way.
      if (err.pending) {
        say(ui.mapOut, `${short(err.hash)} is still pending — watch the lean column, it shows when it lands.`,
          false, explorerTx(view.state.chain, err.hash));
      } else {
        say(ui.mapOut, err.message ?? String(err), true);
      }
    } finally {
      ui.mapGo.disabled = false;
    }
  });
}

/**
 * Sign in, and the twenty seconds it is supposed to take.
 *
 * A visitor with no extension and no seed phrase types an email address, receives a six-digit code
 * and has a wallet on the chain this page is reading. That is the taker path this console is
 * judged on: everything after it — mint, approve, swap — is the same three transactions whichever
 * key signs them, which is why there is one signer interface and not two flows.
 *
 * A browser wallet is still offered, second, for whoever already has one.
 */
function wireSignIn(view) {
  const { ui, state } = view;
  let session = null;   // the Privy session, once the SDK has been fetched
  let emailed = null;   // the address a code was sent to

  const setSigner = (signer) => {
    view.signer = signer;
    // A resumed session can land before the first read does, and `render` wants a floor to draw.
    // The next tick is two seconds away and repaints everything anyway.
    if (view.floor) render(view);
    paint();
  };

  const paint = () => {
    const signed = Boolean(view.signer);
    ui.who.hidden = !signed;
    ui.signOut.hidden = !signed;
    ui.email.hidden = signed;
    ui.signInGo.hidden = signed;
    ui.connect.hidden = signed || !globalThis.ethereum;
    ui.code.hidden = signed || !emailed;
    if (signed) {
      ui.who.textContent = `${view.signer.label} · ${short(view.signer.address)}`;
      ui.who.title = view.signer.address;
    }
    ui.signInGo.textContent = emailed ? "sign in" : "email me a code";
  };

  if (!state.privy) {
    ui.email.hidden = true;
    ui.signInGo.hidden = true;
    say(ui.signInNote, "Privy is not configured on this deployment (app/privy.json has no app id).", true);
  }

  ui.signInGo.addEventListener("click", async () => {
    if (!state.privy) return;
    try {
      ui.signInGo.disabled = true;
      session ??= await openPrivy(state.chain, state.privy);
      if (!emailed) {
        const address = ui.email.value.trim();
        if (!address.includes("@")) return say(ui.signInNote, "an email address, please", true);
        await session.sendCode(address);
        emailed = address;
        say(ui.signInNote, `code sent to ${address}`);
        paint();
        ui.code.focus();
        return;
      }
      const code = ui.code.value.trim();
      if (!code) return say(ui.signInNote, "the six digits from the email", true);
      say(ui.signInNote, "signing in and creating a wallet…");
      setSigner(await session.submitCode(emailed, code));
      say(ui.signInNote, "this wallet is yours; nothing was installed.");
    } catch (err) {
      say(ui.signInNote, err.message ?? String(err), true);
    } finally {
      ui.signInGo.disabled = false;
    }
  });

  ui.code.addEventListener("keydown", (e) => { if (e.key === "Enter") ui.signInGo.click(); });
  ui.email.addEventListener("keydown", (e) => { if (e.key === "Enter") ui.signInGo.click(); });

  ui.connect.addEventListener("click", async () => {
    const signer = injected(state.chain);
    if (!signer) return say(ui.signInNote, "no wallet in this browser", true);
    try {
      ui.connect.disabled = true;
      setSigner(await signer.connect());
      signer.onChanged(async () => {
        // An injected wallet can be moved off this chain from outside the page, so unlike the
        // embedded one it is re-checked rather than assumed.
        if (!(await signer.onChain())) await signer.switchToChain();
        await signer.resume();
        if (view.floor) render(view);
        paint();
      });
      say(ui.signInNote, "");
    } catch (err) {
      say(ui.signInNote, err.message ?? String(err), true);
    } finally {
      ui.connect.disabled = false;
    }
  });

  ui.signOut.addEventListener("click", async () => {
    await view.signer?.disconnect();
    emailed = null;
    ui.code.value = "";
    setSigner(null);
    say(ui.signInNote, "");
  });

  // Whoever was already signed in on this device, without a prompt: a Privy session survives a
  // reload, and an injected wallet the page has been allowed before answers eth_accounts.
  //
  // The Privy half is guarded on the refresh token Privy's own storage adapter leaves behind. A
  // visitor who has never signed in has no such key, so the 836 kB bundle is not fetched to be told
  // there is no session — which is the whole reason it is a lazy import.
  (async () => {
    const already = injected(state.chain);
    if (already && (await already.resume()) && (await already.onChain())) return setSigner(already);
    if (!state.privy || !hasPrivySession()) return;
    try {
      session = await openPrivy(state.chain, state.privy);
      const signer = await session.resume();
      if (signer) setSigner(signer);
    } catch { /* the session expired, or the SDK is unreachable; the buttons still work */ }
  })();

  paint();
}

// ---- helpers ----

/** Privy's own storage adapter writes this key. Private-mode browsers throw on access, hence try. */
function hasPrivySession() {
  try {
    return localStorage.getItem("privy:refresh_token") !== null;
  } catch {
    return false;
  }
}

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

function say(node, text, isError = false, link = null) {
  node.textContent = text;
  node.className = isError ? "out out-error" : "out";
  if (!link) return;
  const a = document.createElement("a");
  a.href = link;
  a.target = "_blank";
  a.rel = "noreferrer";
  a.textContent = " — on the explorer";
  node.append(a);
}

function build(root) {
  const id = (name) => root.querySelector(`#${name}`);
  return {
    status: id("floor-status"), page: id("floor-page"), error: id("floor-error"),
    mode: id("floor-mode"), meta: id("floor-meta"),
    book: id("floor-book"), arb: id("floor-arb"), regime: id("floor-regime"), strip: id("floor-strip"),
    rows: id("floor-rows"), connect: id("floor-connect"),
    who: id("floor-who"), email: id("signin-email"), code: id("signin-code"),
    signInGo: id("signin-go"), signOut: id("signin-out"), signInNote: id("signin-note"),
    takeDesk: id("take-desk"), takeSide: id("take-side"), takeAmount: id("take-amount"),
    takeGo: id("take-go"), takeOut: id("take-out"), takeNote: id("take-note"),
    mapDesk: id("map-desk"), mapSide: id("map-side"), mapNotional: id("map-notional"),
    mapGo: id("map-go"), mapOut: id("map-out"), mapNote: id("map-note"),
  };
}
