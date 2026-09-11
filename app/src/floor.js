// The Desk: one claim, the two books, and the button that fires the map for real.
//
// The page's job is fifteen seconds long: the sentence, the zero, the strip. Everything else —
// the desks, the take flow, the proof — is below that fold. The zero is recomputed every block
// from the frame on the screen, but its ground is the record: the days the desks have been
// quoting and the fills they have signed, read from the same file the Record tab plots. Beside
// the zero, the toll at both its scales at once: the accumulated total a plain curve on the same
// reserves would have paid over every trade the record holds, and this block's live slice of it,
// with its bps and its block number — the total is only credible if the accumulation is visible.
// Neither is asserted; both are re-derived from data the visitor can open.

import {
  Rpc, plant, loadSelectors, readFloor, readOrder, takerTraits, quoteCall, swapCall,
  erc20, mapUpdate, paramsTuple, decode,
} from "./chain.js";
import { waitForReceipt, DEFAULT_RPCS } from "./rpc.js";
import { chainFor, explorerTx, injected, openPrivy, privyConfig } from "./signer.js";
import { roundTrip, bestRoundTrip, bestControlToll } from "./arb.js";
import { recordFacts, onRecord } from "./record.js";

// Four seconds, not two: HyperEVM blocks are not twice-a-second events, and nothing a visitor can
// see changes between two polls that a slightly slower one misses. What the faster cadence did buy
// was the official node rate-limiting the page itself.
const POLL_MS = 4000;

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

/**
 * What the stress button writes: forced selling below mark, the size the map panel already offers.
 * The absorbing side it lights is the bid — the desk stepping in to buy from forced sellers.
 */
const STRESS_NOTIONAL = 40_000_000n;

export async function mountFloor(root) {
  const ui = build(root);
  // `?rpc=` pins one endpoint, for debugging against a specific node. Without it the page carries
  // the list: the first endpoint to answer a throttle with silence (or a 429, or a -32005) is
  // cooled down and the next one takes over, per the cascade in rpc.js.
  const params = new URLSearchParams(location.search);
  const rpc = new Rpc(params.get("rpc") ? [params.get("rpc")] : DEFAULT_RPCS);

  let state;
  try {
    state = await connectToChain(rpc, rpc.url);
  } catch (err) {
    ui.status.className = "status error";
    ui.status.textContent = `Could not reach any RPC endpoint (${rpc.urls.join(", ")}).\n\n${err.message}`;
    return;
  }
  ui.status.remove();
  ui.page.hidden = false;

  const view = {
    state, rpc, ui,
    floor: null,
    signer: null,
    // The record the zero stands on: days quoting, fills signed, none inside the band, and the
    // accumulated toll a plain curve would have paid over those trades. Filled by mountRecord's
    // shared read of the same file the Record tab plots; null until the first render arrives.
    record: null,
    // The live accumulator: the best (least negative) round trip offered since this page was
    // opened. It only ever moves toward zero; the clamp is why it never crosses.
    sessionBest: null,
    mapPending: null,   // {hash, clearing} of a map write whose block has not landed yet
    regimeHtml: "",     // the last regime line painted — repaints are skipped while it holds
    bookPrev: null,     // the last book painted — a cell flashes when its raw value moved
  };

  const auth = createAuth(view);
  wireSignInPanel(view, auth);
  wireStressAuth(view, auth);
  wireTake(view);
  wireStress(view);
  wireMap(view);

  // The zero's ground is the record, not the session: the Record tab's mount already polls the
  // file on its own cadence, so the hero subscribes to the same read rather than fetching a copy.
  onRecord((doc) => {
    view.record = recordFacts(doc);
    if (view.floor) render(view);
  });

  // A tick is one HTTP request by construction: the loop awaits the read before scheduling the
  // next, so a slow node makes a slower page, never a pile-up of overlapping eth_calls — which is
  // what a fixed setInterval produced whenever a read outlived the interval. When the read fails
  // the page says so (that rule has not moved) and the interval doubles — 4s, 8s, 16s… to a
  // minute — until an answer comes back, on top of the transport failing over to the next
  // endpoint underneath. A success resets the cadence to POLL_MS.
  let failures = 0;
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
      failures = 0;
    } catch (err) {
      failures += 1;
      ui.error.hidden = false;
      ui.error.textContent = `read failed: ${err.message}`;
    }
    setTimeout(tick, failures === 0 ? POLL_MS : Math.min(60_000, POLL_MS * 2 ** failures));
  };
  await tick();

  // The expiry line is a wall-clock countdown against the map's own timestamps, so it keeps
  // moving between chain reads. It only paints while a map is live; the next read after the
  // lapse repaints the line from the chain's answer.
  setInterval(() => {
    if (view.mapPending) return; // the pending write owns the line until its block lands
    const demo = demoDesk(view);
    if (!demo || !mapLive(demo)) return;
    const left = demo.map.updatedAt + demo.params.mapMaxAge - Math.floor(Date.now() / 1000);
    if (left <= 0) return;
    const mm = Math.floor(left / 60), ss = String(left % 60).padStart(2, "0");
    say(ui.stressOut,
      `map live — the desk steps back out on its own in ${mm}:${ss}. The round trip above has not moved.`);
  }, 1000);
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
      // `filter(Boolean)` is what lets a desk be added to the address book without touching this
      // file again, and what lets this line name one that does not exist yet. The list is explicit
      // rather than discovered from `DeskOpened`, because the page has no indexer: it holds the
      // addresses it was deployed with and reads them straight from the node.
      accounts: [deployment.canonicalDesk, deployment.demoDesk, deployment.hedgedDesk].filter(Boolean),
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

  ui.mode.textContent = state.mode === "deployed" ? "live" : "simulated";
  ui.mode.className = `chip chip-${state.mode}`;
  ui.meta.innerHTML =
    `<span class="dot"></span>block ${floor.blockNumber.toLocaleString("en-US")}` +
    ` · ${state.chain.name} · ${new Date().toLocaleTimeString("en-US", { hour12: false })}`;

  if (!bookOk) {
    ui.live.textContent =
      "the book could not be read this block — an empty field here means a read failed, not that a number was zero";
    ui.regime.textContent = "";
    view.regimeHtml = ""; // the memo must not skip the repaint once the book is back
    return;
  }
  const dislocation = Number(book.oracle) === 0 ? 0
    : Number((BigInt(book.oracle) - BigInt(book.mark)) * 10_000n / BigInt(book.oracle));

  // Every number on this row is a live chain read, and the page says so by behaviour rather than
  // by label: a changed value flashes its own cell for a second and a half, so "live" is seen,
  // not claimed. The comparison is on the raw bigint, so formatting never masks a move.
  const prevBook = view.bookPrev;
  view.bookPrev = { bid: book.bid, ask: book.ask, mark: book.mark, oracle: book.oracle };
  const moved = (v, k) => prevBook != null && String(prevBook[k]) !== String(v);
  ui.book.replaceChildren(
    cell("the book's bid", px2(book.bid), undefined, moved(book.bid, "bid")),
    cell("ask", px2(book.ask), undefined, moved(book.ask, "ask")),
    cell("mark", px0(book.mark), undefined, moved(book.mark, "mark")),
    cell("oracle", px0(book.oracle), undefined, moved(book.oracle, "oracle")),
    cell("oracle − mark", `${dislocation > 0 ? "+" : ""}${dislocation} bps`, "past 25 bps the desk steps in on its own"),
  );

  const best = bestRoundTrip(book, desks);
  if (best && (view.sessionBest === null || best.trip.best > view.sessionBest.trip.best)) {
    view.sessionBest = best;
  }
  renderVerdict(view, best);
  renderRegime(view, desks);

  renderStress(view);
  renderTable(view, desks, book);
  renderPanels(view, desks);
}

/**
 * The number the whole page is about.
 *
 * It is one subtraction on two prices out of the same `eth_call`, and the reason it is worth a
 * headline is that it does not need a cascade to be true. `app/src/arb.js` has the arithmetic and
 * `test/Inarbitrable.t.sol` has the same round trip asserted against the contract, fuzzed.
 *
 * What the number is measured against is Hyperliquid's book — one venue, one instant, one
 * instrument — and the line under it says so, grounded in the record rather than in how long the
 * page has been open: the days the desks have been quoting and the fills they have signed are the
 * claim; the session's closest attempt is only the live check. If a positive ever appears it is
 * shown, in red, with an invitation to take it: a page that hides its own failure is a maquette.
 */
function renderVerdict(view, best) {
  const { ui } = view;
  const rec = view.record;

  // The record door carries the one sentence the whole floor stands on, and the count that
  // makes it checkable. It waits for the artifact rather than inventing a placeholder.
  if (rec) {
    ui.doorRecordV.textContent = `${rec.fills} fills`;
    ui.doorRecordS.innerHTML = rec.inside === 0
      ? `not one of them priced inside Hyperliquid's own touch — every quote was read from the ` +
        `book inside the trade that took it`
      : `<b style="color:var(--loss)">${rec.inside} priced inside the touch — look at them</b>`;
  }

  if (!best) {
    ui.live.textContent =
      "no desk on this screen has a price right now, so there is nothing to search against.";
    return;
  }

  // The live line: what the same search takes off an ordinary curve on these reserves, this
  // block. It is cents most blocks and it is named as this block's, not as a rate.
  const session = view.sessionBest;
  const toll = bestControlToll(view.floor.book, view.floor.desks);
  const block = view.floor.blockNumber.toLocaleString("en-US");

  if (session.trip.best > 0) {
    ui.live.innerHTML =
      `<b style="color:var(--loss)">${escape(name(session.desk))} can be taken and closed at the ` +
      `book for a profit right now</b> — that is not supposed to be reachable. Read it as a book ` +
      `that moved between two reads, or as a bug, and take it before it closes.`;
    return;
  }

  const head = `this block, ${block}: <b>nothing to take from these desks</b>`;
  if (toll && toll.usd > 0.005) {
    ui.live.innerHTML =
      `${head} — the same search against a baseline curve on the same reserves takes ` +
      `<b class="loss">+$${toll.usd.toFixed(2)} · +${toll.bps.toFixed(1)} bps</b>`;
  } else if (toll) {
    ui.live.innerHTML =
      `${head}, and nothing from a baseline curve either — a curve pays when its ratio drifts ` +
      `from the book, and right now it has not`;
  } else {
    ui.live.innerHTML = `${head} — reserves too thin to quote a rate against a curve`;
  }
}

/** What the floor is doing, said as what a stranger sees. */
function renderRegime(view, desks) {
  const leaning = desks.filter((d) => d.lean !== 0);
  const { ui } = view;
  const on = leaning.length > 0;

  // Two states, both always named, one of them lit. Which regime the desk is in is the single
  // most load-bearing fact on this screen, and a sentence that only describes the current one
  // leaves a reader with no idea that a second one exists.
  const where = on
    ? leaning.map((d) => `${name(d)} on the ${d.lean === 1 ? "bid" : "ask"}`).join(", ")
    : "";
  // `data-tip`, not `title`: the poll repaints this line every few seconds, and a native
  // tooltip dies with the node under it before it can open. The CSS bubble reads the attribute
  // on :hover — and the repaint is skipped outright while nothing changed, so an open bubble
  // is never clobbered mid-read.
  const html =
    `<span class="tag${on ? "" : " tag-on"}" data-tip="The desk quotes outside the book's touch on ` +
    `both sides, so a round trip through it and back to Hyperliquid always loses. The everyday ` +
    `state.">quiet</span>` +
    `<span class="tag${on ? " tag-on tag-step" : ""}" data-tip="Forced sellers are eating the bid, or ` +
    `a liquidation map says they are about to. One condition flips: the desk quotes inside the gap ` +
    `they opened and becomes the best bid in the market.">cascade</span>` +
    (on
      ? `<span class="tag-note">${escape(where)} — capped at the book's own price</span>`
      : `<span class="tag-note">sitting outside the book on both sides</span>`);
  if (view.regimeHtml !== html) {
    view.regimeHtml = html;
    ui.regime.innerHTML = html;
  }
  ui.regime.className = on ? "regime step" : "regime";
}

function renderTable(view, desks, book) {
  const rows = desks.map((d) => {
    const trip = roundTrip(book, d);
    const tr = document.createElement("tr");

    const nameTd = document.createElement("td");
    nameTd.className = "name";
    nameTd.textContent = name(d);
    if (d.account !== ZERO) {
      const small = document.createElement("small");
      small.textContent = short(d.account);
      nameTd.append(small);
    }
    tr.append(nameTd);

    const quote = d.quoted ? `${px2(d.bidPx)} / ${px2(d.askPx)}` : "no price";
    // The margin is this desk's quietBps — a parameter it chose, not a property of the product.
    // The invariant the page claims is the book's touch; this column is where each desk decided
    // to sit above it.
    const margin = `${d.params.quietBps} bps outside the book`;
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
      [quote, "num"],
      [trip ? `${bpsText(trip.best)} bps` : "—", trip ? (trip.best > 0 ? "rt-bad" : "rt-good") : ""],
      [margin, ""],
      [inventory, ""], [map, ""], [hedge, ""],
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

// ---- the stress button: a real map, fired from the first click ----

/**
 * The desk whose oracle anyone can write: the one pointing at `DemoMapOracle`. On the canonical
 * desk only the updater can post, which is why the button never offers it — a button that reverts
 * for the person the page is built for is worse than no button.
 */
function demoDesk(view) {
  const { floor, state } = view;
  if (!floor || !state.deployment) return null;
  return floor.desks.find((d) => sameAddress(d.params.mapOracle, state.deployment.demoMapOracle)) ?? null;
}

/**
 * A map counts as live when it is fresh *and* has weight on it. `mapFresh` alone is about
 * staleness — a cleared map (`0 / 0`) is still fresh, and treating it as live would paint a
 * countdown over a lean that does not exist.
 */
const mapLive = (demo) =>
  demo.regime.mapFresh &&
  (demo.map.below >= demo.params.mapMinNotional || demo.map.above >= demo.params.mapMinNotional);

function renderStress(view) {
  const { ui } = view;
  const demo = demoDesk(view);
  if (!demo) {
    ui.stressGo.hidden = true;
    return;
  }
  ui.stressGo.hidden = false;

  const live = mapLive(demo);

  // A pending write is done when the chain's answer matches its intent: a posted map when the lean
  // comes live, a cleared one when it goes dead. Until then the button stays put — re-arming it
  // early is how the same map gets posted twice.
  if (view.mapPending && live === !view.mapPending.clearing) view.mapPending = null;

  if (view.mapPending) {
    ui.stressGo.disabled = true;
    ui.stressGo.textContent = "waiting for the block…";
    return;
  }

  if (live) {
    ui.stressGo.disabled = false;
    ui.stressGo.textContent = "take the map away";
    // The countdown line is painted by the one-second clock; nothing to say here.
    return;
  }

  // Same contract as Take: the button is inactive while no wallet is connected, and nothing is
  // said about it. The wallet form sits two rows above it; a second message under this one only
  // duplicated the other.
  if (live) {
    ui.stressGo.disabled = !view.signer;
    ui.stressGo.textContent = "take the map away";
    // The countdown line is painted by the one-second clock; nothing to say here.
    return;
  }

  // Already leaning on the book alone: the map would be redundant, and saying so is the demo of
  // the book-only half. The button idles rather than posting a map that changes nothing.
  if (demo.lean !== 0) {
    ui.stressGo.disabled = !view.signer;
    ui.stressGo.textContent = "watch it step in ▸";
    say(ui.stressOut,
      "the book is already stressed — it stepped in without any map. That half needs nothing but the chain.");
    return;
  }

  ui.stressGo.disabled = !view.signer;
  ui.stressGo.textContent = "post it and watch ▸";
}

function wireStress(view) {
  const { ui } = view;

  ui.stressGo.addEventListener("click", async () => {
    const demo = demoDesk(view);
    if (!demo) return;
    const clearing = mapLive(demo);

    // The button stays inactive without a signer, so this branch can only trip on a race.
    if (!view.signer) return;

    try {
      ui.stressGo.disabled = true;
      const signer = view.signer;
      await signer.switchToChain();
      say(ui.stressOut, "checking this wallet for gas…");
      await signer.fund(view.rpc);
      say(ui.stressOut, clearing ? "taking the map away — one transaction…" : "posting the map — one transaction…");
      const hash = await signer.send({
        from: signer.address,
        to: demo.params.mapOracle,
        data: clearing
          ? mapUpdate(view.state.sel, demo.params.perpIndex, 0n, 0n)
          : mapUpdate(view.state.sel, demo.params.perpIndex, STRESS_NOTIONAL, 0n),
      });
      view.mapPending = { hash, clearing };
      say(ui.stressOut,
        clearing
          ? `cleared ${short(hash)} — the desk steps back out when this block lands`
          : `posted ${short(hash)} — the desk steps in when this block lands, and back out on its own ` +
            `${Math.round(demo.params.mapMaxAge / 60)} minutes later`,
        false, explorerTx(view.state.chain, hash));
      renderStress(view);
      // The receipt is deliberately not awaited. The strip drawing the lean from the next chain
      // read is the proof that the chain answered rather than the page; a spinner until then would
      // make the page the thing being watched.
      waitForReceipt(view.rpc, hash).catch(() => {});
    } catch (err) {
      // Giving up on a receipt is not the write failing, and the lean shows on the next tick
      // either way — same rule as Take.
      if (err.pending) {
        view.mapPending = { hash: err.hash, clearing };
        say(ui.stressOut, `${short(err.hash)} sent, still pending — the strip shows the lean when it lands.`,
          false, explorerTx(view.state.chain, err.hash));
      } else {
        view.mapPending = null;
        say(ui.stressOut, walletError(err), true);
      }
      renderStress(view);
    } finally {
      ui.stressGo.disabled = false;
    }
  });
}

// ---- the two buttons' shared plumbing ----

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
    ? "No desk is deployed yet; Take turns on when the desks are on chain."
    : !view.signer
      ? "One swap through the official SwapVM router. An email address is enough — the wallet that appears is the one that signs it."
      : mintable
        ? "Three transactions: mint the demo token, approve the router, swap through the official SwapVM router. Sell base to watch the bound bite — the desk's bid is clamped to the book's own."
        : `This desk trades the real pair: bring your own ${chosen ? short(chosen.params.base) : "tokens"}, or take the demo desk for nothing.`;
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

  // The default amount is per side, because the two sides are measured in different units and the
  // clamp is only visible on one of them: selling base shows the desk's bid pinned to the book's,
  // buying shows an ordinary curve. A sane default is the difference between a judge seeing the
  // mechanism and a judge reverting the demo desk.
  const defaultAmount = () => { ui.takeAmount.value = ui.takeSide.value === "sell" ? "0.001" : "10"; };
  ui.takeSide.addEventListener("change", defaultAmount);
  defaultAmount();

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

      // What crossing the book would give, so the number has something to be compared to.
      const crossing = sellBase
        ? amountIn * BigInt(view.floor.book.bid) * desk.params.pxNum / desk.params.pxDen
        : amountIn * desk.params.pxDen / (BigInt(view.floor.book.ask) * desk.params.pxNum);
      const edge = crossing === 0n ? 0 : Number((amountOut - crossing) * 10_000n / crossing);
      say(ui.takeOut,
        `quote: ${amount(amountOut, sellBase ? 6 : 8)} out for ${amount(amountInQ, decimalsIn)} in — ` +
        `${edge >= 0 ? "+" : ""}${edge} bps against crossing the book. three transactions from here; ` +
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
        say(ui.takeOut, walletError(err), true);
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
  // The two reads are independent of each other and of the mint below, so they go as one
  // JSON-RPC batch: one HTTP request instead of two.
  const [balanceHex, allowanceHex] = await rpc.batch([
    { method: "eth_call", params: [{ to: token, data: erc20.balanceOf(state.sel, account) }, "latest"] },
    { method: "eth_call", params: [{ to: token, data: erc20.allowance(state.sel, account, spender) }, "latest"] },
  ]);
  if (BigInt(balanceHex) < needed && isDemoToken(state, token)) {
    say(out, "minting the demo token — 1 of 3");
    const hash = await signer.send({ from: account, to: token, data: erc20.mint(state.sel, account, needed - balance) });
    await waitForReceipt(rpc, hash);
  }
  if (BigInt(allowanceHex) >= needed) return;
  say(out, "approving the router — 2 of 3");
  const hash = await signer.send({ from: account, to: token, data: erc20.approve(state.sel, spender, needed) });
  await waitForReceipt(rpc, hash);
}

const isDemoToken = (state, token) =>
  state.deployment && [state.deployment.demoBase, state.deployment.demoQuote].some((t) => sameAddress(t, token));

/**
 * The map panel's write, labelled as what it is.
 *
 * The map is the one input the design takes on trust: it is reconstructed off chain, it can only
 * ever *add* a lean, and a stale one is ignored. The stress button above posts the same write with
 * no choices; this fold keeps the full controls for whoever wants the other side or another size.
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
      if (err.pending) {
        say(ui.mapOut, `${short(err.hash)} is still pending — watch the strip, it shows when it lands.`,
          false, explorerTx(view.state.chain, err.hash));
      } else {
        say(ui.mapOut, walletError(err), true);
      }
    } finally {
      ui.mapGo.disabled = false;
    }
  });
}

// ---- sign-in, one session shared by the Take panel and the strip's compact row ----

/**
 * One wallet, two surfaces.
 *
 * The session — the Privy client, the address a code was mailed to, the signer itself — is a
 * single thing, created once per page. Both the Take panel's full row and the strip's compact row
 * are views over it, subscribing to repaints rather than owning state: a code mailed from the
 * strip is a code the Take panel knows about, because the fifteen-second path and the thirty-
 * second path are the same person.
 */
function createAuth(view) {
  const { state } = view;
  let privySession = null;
  let emailed = null;
  const paints = new Set();

  const repaint = () => { for (const paint of paints) paint(); };
  const setSigner = (signer) => {
    view.signer = signer;
    // A resumed session can land before the first read does, and `render` wants a floor to draw.
    // The next tick is a few seconds away and repaints everything anyway.
    if (view.floor) render(view);
    repaint();
  };

  const auth = {
    get emailed() { return emailed; },

    subscribe(paint) { paints.add(paint); paint(); },

    async sendCode(email) {
      if (!state.privy) throw new Error("Privy is not configured on this deployment (app/privy.json has no app id).");
      privySession ??= await openPrivy(state.chain, state.privy);
      await privySession.sendCode(email);
      emailed = email;
      repaint();
    },

    async submitCode(code) {
      if (!emailed) throw new Error("send yourself a code first");
      privySession ??= await openPrivy(state.chain, state.privy);
      const signer = await privySession.submitCode(emailed, code);
      emailed = null;
      setSigner(signer);
    },

    async connectInjected() {
      const signer = injected(state.chain);
      if (!signer) throw new Error("no wallet in this browser");
      await signer.connect();
      signer.onChanged(async () => {
        // An injected wallet can be moved off this chain from outside the page, so unlike the
        // embedded one it is re-checked rather than assumed.
        if (!(await signer.onChain())) await signer.switchToChain();
        await signer.resume();
        if (view.floor) render(view);
        repaint();
      });
      setSigner(signer);
    },

    async signOut() {
      await view.signer?.disconnect();
      setSigner(null);
    },
  };

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
      privySession = await openPrivy(state.chain, state.privy);
      const signer = await privySession.resume();
      if (signer) setSigner(signer);
    } catch { /* the session expired, or the SDK is unreachable; the buttons still work */ }
  })();

  return auth;
}

/** The Take panel's full row: email, code, the injected wallet, sign out. */
function wireSignInPanel(view, auth) {
  const { ui, state } = view;

  auth.subscribe(() => {
    const signed = Boolean(view.signer);
    const mailed = Boolean(auth.emailed);
    ui.who.hidden = !signed;
    ui.signOut.hidden = !signed;
    ui.email.hidden = signed || mailed;
    ui.code.hidden = signed || !mailed;
    ui.signInGo.hidden = signed;
    ui.connect.hidden = signed || mailed || !globalThis.ethereum;
    if (signed) {
      ui.who.textContent = `${view.signer.label} · ${short(view.signer.address)}`;
      ui.who.title = view.signer.address;
    }
    ui.signInGo.textContent = mailed ? "sign in" : "email me a code";
  });

  if (!state.privy) {
    say(ui.signInNote, "Privy is not configured on this deployment (app/privy.json has no app id).", true);
  }

  ui.signInGo.addEventListener("click", async () => {
    try {
      ui.signInGo.disabled = true;
      if (!auth.emailed) {
        const address = ui.email.value.trim();
        if (!address.includes("@")) return say(ui.signInNote, "an email address, please", true);
        await auth.sendCode(address);
        say(ui.signInNote, `code sent to ${address}`);
        ui.code.focus();
        return;
      }
      const code = ui.code.value.trim();
      if (!code) return say(ui.signInNote, "the six digits from the email", true);
      say(ui.signInNote, "signing in and creating a wallet…");
      await auth.submitCode(code);
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
    try {
      ui.connect.disabled = true;
      await auth.connectInjected();
      say(ui.signInNote, "");
    } catch (err) {
      say(ui.signInNote, walletError(err), true);
    } finally {
      ui.connect.disabled = false;
    }
  });

  ui.signOut.addEventListener("click", async () => {
    await auth.signOut();
    ui.code.value = "";
    say(ui.signInNote, "");
  });
}

/**
 * The strip's compact row — the stress button's first click for a visitor with no wallet. It is
 * deliberately narrower than the panel's: no injected option, no sign-out, just the email that
 * arms the button they just pressed. Anything else is a detour from the thing they came to watch.
 */
function wireStressAuth(view, auth) {
  const { ui } = view;

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

/** Raw book price to dollars: raw / 10^(6 - szDecimals), and BTC's szDecimals is 5. */
const px0 = (raw) => `$${Math.round(Number(raw) / 10).toLocaleString("en-US")}`;
const px2 = (raw) => `$${(Number(raw) / 10).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

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
const bpsText = (v) => `${v > 0 ? "+" : v < 0 ? "−" : ""}${Math.abs(v).toFixed(2)}`;

const escape = (s) => s.replace(/[<>&]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;" })[c]);

/**
 * The wallet's own refusals, translated into what to do about them. -32002 is the one that
 * matters: a request from this page is still open inside the wallet — usually a popup that
 * lost focus or survived a reload — and every click fails with the same raw message until the
 * visitor answers or dismisses the one that is waiting. The raw text says "please wait";
 * waiting is the one thing that does not help.
 */
const walletError = (err) => {
  if (err?.code === -32002)
    return "the wallet already has a request from this page waiting on you — open it, answer or dismiss it, then click again";
  if (err?.code === 4001) return "declined in the wallet — nothing was connected";
  return err?.message ?? String(err);
};

function cell(label, value, sub, tick = false) {
  const node = document.createElement("div");
  node.className = "cell";
  const k = document.createElement("div");
  k.className = "cell-k";
  k.textContent = label;
  const v = document.createElement("div");
  v.className = tick ? "cell-v tick" : "cell-v";
  v.textContent = value;
  node.append(k, v);
  if (sub) {
    const s = document.createElement("div");
    s.className = "cell-s";
    s.textContent = sub;
    node.append(s);
  }
  return node;
}

function leg(label, value, muted = false) {
  const row = document.createElement("div");
  row.className = "arb-leg";
  const k = document.createElement("div");
  k.className = "arb-leg-k";
  k.textContent = label;
  const v = document.createElement("div");
  v.className = `arb-leg-v${muted ? " arb-muted" : ""}`;
  v.textContent = value;
  row.append(k, v);
  return row;
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

/** The live slice — the same block-named message either way. */
function buildLiveSlice(view) {
  const toll = bestControlToll(view.floor.book, view.floor.desks);
  const block = view.floor.blockNumber.toLocaleString("en-US");
  if (toll && toll.usd > 0.005) {
    return `<span class="toll-live">this block, ${block}: <b>+$${toll.usd.toFixed(2)} · ` +
      `+${toll.bps.toFixed(1)} bps</b></span>`;
  }
  if (toll) {
    return `<span class="toll-live toll-empty">this block, ${block}: nothing to take — a plain ` +
      `curve pays when its ratio drifts from the book, and right now it has not</span>`;
  }
  return `<span class="toll-live">this block, ${block}: <b>reserves too thin to quote a rate</b></span>`;
}

function build(root) {
  const id = (name) => root.querySelector(`#${name}`);
  return {
    status: id("floor-status"), page: id("floor-page"), error: id("floor-error"),
    mode: id("floor-mode"), meta: id("floor-meta"),
    live: id("hero-live"),
    doorRecordV: id("door-record-v"), doorRecordS: id("door-record-s"),
    book: id("floor-book"), regime: id("floor-regime"),
    stressGo: id("stress-go"), stressOut: id("stress-out"),
    stressNotional: id("stress-notional"),
    rows: id("floor-rows"),
    who: id("floor-who"), email: id("signin-email"), code: id("signin-code"),
    signInGo: id("signin-go"), signOut: id("signin-out"), signInNote: id("signin-note"),
    connect: id("floor-connect"),
    takeDesk: id("take-desk"), takeSide: id("take-side"), takeAmount: id("take-amount"),
    takeGo: id("take-go"), takeOut: id("take-out"), takeNote: id("take-note"),
    mapDesk: id("map-desk"), mapSide: id("map-side"), mapNotional: id("map-notional"),
    mapGo: id("map-go"), mapOut: id("map-out"), mapNote: id("map-note"),
  };
}
