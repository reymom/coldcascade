// The desk's record: every fill it has signed, priced against the book its quote read.
//
// The Floor's strip is one block; this is the same distance — a fill's price against the book's
// own touch — for every fill the desk has ever signed, over days. The band around the touch is
// the dead zone: the desk's price is min(curve, bound), the bound never improves on the book, so
// no fill can land inside it. The dots pinned on its edge are the bound doing its work.
//
// The file is written by the markout cadence (keeper/coldcascade/markouts.py) and redeployed
// every twenty minutes; the page rereads it once a minute and says how old it is. Fills are
// streamed by a Substreams module on The Graph Market. The book series is a log the floor writes
// itself once a minute, because HyperCore's precompiles answer with the present whatever block tag
// you ask for — the BBO is node state, not chain state, so a Substreams module can only see it
// once somebody has written the words into a log. That writing is BookCache.poke: permissionless,
// four words, one poke a minute — and it is why the record starts when the series starts, and why
// fills before it are marked "before the series" rather than given a number they cannot have.

import { chainFor, explorerTx } from "./signer.js";

const FILE = "../results/markouts.json";
const POLL_MS = 60_000;

const W = 1000;
const PAD = { left: 66, right: 14, top: 34 };
const CH = 240;   // the chart's height
const DATES = 26; // the date axis row
const SPINE = 34; // the book-series row

// Out of the chart, by name. 0x17f1ab16… is the operatorDesk take that built the exposure the
// hedge then covered: its price came from the reserves the strategy was shipped with — poolDev
// +167,764 bps, another regime entirely — not from a quote the bound held against the book, so it
// says nothing about the dead zone this chart exists to show. Left in place it just reads as the
// desk handing a taker 84% under the book, when the taker was us. It stays in the artifact and in
// the keeper's decision below; only the picture excludes it, and it says so next to the picture.
const NOT_A_CLAMP_FILL = new Set([
  "0x17f1ab1670e3175cf738e16efc7156e341253f13f9ec054a55de87c0150b3799",
]);

// One poll, every reader. The Record tab renders the panel; the Desk's hero only reduces each
// fresh document with recordFacts — both read the same fetch, so the hero subscribes instead of
// mounting a second poller.
const subscribers = new Set();
let lastDoc = null;

/** Handed each fresh markouts document, and the current one immediately if the poll has run. */
export function onRecord(fn) {
  subscribers.add(fn);
  if (lastDoc) fn(lastDoc);
}

export async function mountRecord(root) {
  const ui = {
    chart: root.querySelector("#record-chart"),
    count: root.querySelector("#record-count"),
    why: root.querySelector("#record-why"),
    whyFull: root.querySelector("#record-why-full"),
    excluded: root.querySelector("#record-excluded"),
    hover: root.querySelector("#record-hover"),
    decision: root.querySelector("#record-decision"),
    decisionRows: root.querySelector("#record-decision-rows"),
    decisionTail: root.querySelector("#record-decision-tail"),
    markouts: root.querySelector("#record-markouts"),
    foot: root.querySelector("#record-foot"),
    status: root.querySelector("#record-status"),
  };
  if (!ui.chart) return;

  // Delegated, so the listeners survive the chart re-rendering itself every poll: the dots are
  // replaced, the container is not. Hover shows the fill's row without leaving the page; click
  // keeps opening the transaction on the explorer.
  ui.chart.addEventListener("mouseover", (e) => {
    const dot = e.target.closest("[data-i]");
    if (!dot) return;
    const f = ui.currentFills?.[Number(dot.dataset.i)];
    if (f) showHover(ui, f);
  });
  ui.chart.addEventListener("mouseout", (e) => {
    if (e.target.closest("[data-i]")) hideHover(ui);
  });

  // The ledger's address is deployment metadata, not markout data — it lives in the deployments
  // file, fetched once. The decision panel links it when it has it and names it plainly when not.
  let ledger = null;
  let ledgerTried = false;

  const tick = async () => {
    try {
      const res = await fetch(FILE, { cache: "no-store" });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const doc = await res.json();
      lastDoc = doc;
      for (const fn of subscribers) fn(doc);
      if (!ledgerTried) {
        ledgerTried = true;
        fetch(`../deployments/${doc.chainId ?? 999}.json`)
          .then((r) => (r.ok ? r.json() : null))
          .then((d) => {
            ledger = d?.markoutLedger ?? null;
            render(ui, doc, ledger);
          })
          .catch(() => {});
      }
      render(ui, doc, ledger);
      ui.status.textContent = "";
    } catch (err) {
      // A failed read keeps the last good render and says so. On first load there is nothing to
      // keep, so the status line is the whole section — the honest empty state.
      ui.status.textContent =
        `the record could not be read — ${FILE}: ${err.message}. ` +
        `The markout cadence writes it every twenty minutes, once the desk has fills.`;
    }
  };
  await tick();
  setInterval(tick, POLL_MS);
}

/**
 * What the Desk's hero needs from the record, reduced to four numbers: how long the desks have
 * been quoting, how many fills the chart's set holds, whether any landed inside the band, and
 * the toll a plain curve on the same reserves would have paid over those same trades.
 *
 * The toll is the accumulated half of the hero's toll bar, so its rule is written down here
 * rather than in the hero: per fill, the flat curve would have quoted its own ratio —
 * mid × (1 + poolDev) — and an
 * arbitrageur closing at the book's touch takes the gap, when there is one, at the fill's own
 * size and before slippage. (A flat curve fills its whole clip at the ratio; the desk's own
 * curve is bounded. Both approximations are in the curve's favour, so the sum is a floor on
 * what the curve loses, not a ceiling.) Fills without a poolDev — the keeper could not rebuild
 * the reserves for that block — are counted in `fills` but excluded from the sum, and
 * `tollFills` says how many the sum covers.
 */
export function recordFacts(doc) {
  const all = (doc.fills ?? []).filter((f) => Number.isFinite(f.vsTouchBps) && Number.isFinite(f.at));
  const fills = all.filter((f) => !NOT_A_CLAMP_FILL.has(f.txHash.toLowerCase()));
  const inside = fills.filter((f) => Math.abs(f.vsTouchBps) < zoneOf(f, doc)).length;

  let tollUsd = 0;
  let tollFills = 0;
  for (const f of fills) {
    if (!Number.isFinite(f.poolDevBps) || f.bookOk === false) continue;
    const curve = f.midRaw * (1 + f.poolDevBps / 10_000);   // the flat curve's price, raw units
    const gap = f.makerBuysBase
      ? (curve - f.askRaw) / f.askRaw                        // it would overpay for base
      : (f.bidRaw - curve) / f.bidRaw;                       // or undersell it
    if (gap <= 0) continue;
    tollFills += 1;
    tollUsd += gap * (Number(f.baseRaw) / 1e8) * (f.midRaw / 10);
  }

  const days = Number.isFinite(doc.summary?.spanDays) ? doc.summary.spanDays : null;
  const daysText = days === null ? "—"
    : days < 1 ? `${Math.max(1, Math.round(days * 24))} hours`
    : days < 10 ? `${days.toFixed(1)} days`
    : `${Math.round(days)} days`;
  return { fills: fills.length, inside, daysText, tollUsd, tollFills };
}

/** The fill's own quietBps when the file carries it (it does, per fill); the shipped 20 else. */
const zoneOf = (f, doc) =>
  Number.isFinite(f.quietBps) ? f.quietBps : Number.isFinite(doc.quietBps) ? doc.quietBps : 20;

function render(ui, doc, ledger) {
  // allFills is the artifact — every fill the desks have signed, every desk included. fills is
  // the chart — the ones whose price a quote set, which are the ones that speak about the clamp.
  const allFills = (doc.fills ?? []).filter((f) => Number.isFinite(f.vsTouchBps) && Number.isFinite(f.at));
  const excluded = allFills.filter((f) => NOT_A_CLAMP_FILL.has(f.txHash.toLowerCase()));
  const fills = allFills.filter((f) => !NOT_A_CLAMP_FILL.has(f.txHash.toLowerCase()));
  const books = doc.books ?? {};
  const sum = doc.summary ?? {};
  const chain = chainFor(doc.chainId ?? 999, "");
  const tx = (hash) => explorerTx(chain, hash);

  // The dead zone's drawn half-width is the shipped margin: quietBps, 20 on every desk on the
  // floor. Each fill's own parameter is in the file and decides the count above; the drawn band
  // stays the shipped one and nothing else — the day a fill lands at ±15 the honest picture is a
  // dot inside the band and a mechanism to look at, not a band that quietly redrew itself around
  // it.
  const zone = Number.isFinite(doc.quietBps) ? doc.quietBps : 20;

  // The tab's headline, computed from the same set the chart plots: the fills, the span, and
  // whether any landed inside the band. It is a count, not a claim — the scatter below is the
  // same set one dot per fill, so the sentence is checked against the picture at a glance. The
  // band each fill is measured against is that fill's own quietBps, not a page constant.
  if (ui.count) {
    const inside = fills.filter((f) => Math.abs(f.vsTouchBps) < zoneOf(f, doc)).length;
    const days = Number.isFinite(sum.spanDays) ? sum.spanDays : null;
    const daysText = days === null ? "—"
      : days < 1 ? `${Math.max(1, Math.round(days * 24))} hours`
      : days < 10 ? `${days.toFixed(1)} days`
      : `${Math.round(days)} days`;
    ui.count.innerHTML =
      `<b>${fills.length}</b> fills · ${daysText} · ` +
      (inside === 0
        ? `<span class="ok">none inside the band</span>`
        : `<span class="bad">${inside} inside the band — look at them</span>`);
  }

  const starts = [books.firstAt, ...fills.map((f) => f.at)].filter(Number.isFinite);
  const ends = [books.lastAt, doc.generatedAt, ...fills.map((f) => f.at)].filter(Number.isFinite);
  const now = Math.floor(Date.now() / 1000);
  const lo = (starts.length ? Math.min(...starts) : now - 86400) - 2 * 3600;
  const hi = (ends.length ? Math.max(...ends) : now) + 1800;

  const vs = fills.map((f) => f.vsTouchBps);
  const yLo = Math.min(-zone * 1.7, ...(vs.length ? [Math.min(...vs) * 1.12] : [-60]));
  const yHi = Math.max(zone * 1.7, ...(vs.length ? [Math.max(...vs) * 1.1] : [60]));

  const H = PAD.top + CH + DATES + SPINE;
  const x = (t) => PAD.left + ((t - lo) / (hi - lo)) * (W - PAD.left - PAD.right);
  const y = (v) => PAD.top + ((yHi - v) / (yHi - yLo)) * CH;

  const parts = [];

  // The dead zone and its edges. Fills pinned on the edge are the bound doing its work.
  parts.push(`<rect class="rc-zone" x="${PAD.left}" y="${y(zone)}" width="${W - PAD.left - PAD.right}" height="${y(-zone) - y(zone)}"/>`);
  for (const e of [zone, -zone]) {
    parts.push(`<line class="rc-zone-edge" x1="${PAD.left}" y1="${y(e)}" x2="${W - PAD.right}" y2="${y(e)}"/>`);
  }
  parts.push(`<text class="rc-lab" x="${PAD.left + 10}" y="${y(zone) + 13}">the dead zone — the book's touch is the floor; ±${fmtZone(zone)} bps is the margin these desks chose. No fill lands inside.</text>`);

  // The touch itself, and the hundred-bps gridlines that fit the domain.
  parts.push(`<line class="rc-touch" x1="${PAD.left}" y1="${y(0)}" x2="${W - PAD.right}" y2="${y(0)}"/>`);
  parts.push(`<text class="rc-lab" x="${PAD.left - 6}" y="${y(0) + 3}" text-anchor="end">0</text>`);
  parts.push(`<text class="rc-lab" x="${W - PAD.right}" y="${y(0) - 5}" text-anchor="end">the touch</text>`);
  for (const g of [-100, 100]) {
    if (g <= yLo || g >= yHi) continue;
    parts.push(`<line class="rc-grid" x1="${PAD.left}" y1="${y(g)}" x2="${W - PAD.right}" y2="${y(g)}"/>`);
    parts.push(`<text class="rc-lab" x="${PAD.left - 6}" y="${y(g) + 3}" text-anchor="end">${g > 0 ? "+" : "−"}${Math.abs(g)}</text>`);
  }

  // Where the book series starts. Everything left of this line is the era the markouts call
  // "before the series" — there was no log to mark a fill out against.
  if (Number.isFinite(books.firstAt) && books.firstAt > lo && books.firstAt < hi) {
    parts.push(`<line class="rc-divider" x1="${x(books.firstAt)}" y1="${PAD.top - 8}" x2="${x(books.firstAt)}" y2="${PAD.top + CH}"/>`);
    parts.push(`<text class="rc-lab" x="${x(books.firstAt) - 6}" y="${PAD.top - 12}" text-anchor="end">the book series starts</text>`);
  }

  // The fills. Amber the desk bought base, teal it sold. Click still opens the transaction on
  // the explorer; hover stays on the page and shows the fill's row — when it happened, which
  // side, where it printed, and where the book went after — in the readout under the chart.
  ui.currentFills = fills;
  fills.forEach((f, i) => {
    const side = f.makerBuysBase ? "buy" : "sell";
    const cls = `rc-dot rc-${side}${f.bookOk === false ? " rc-nobook" : ""}`;
    const dot = `<circle class="${cls}" data-i="${i}" cx="${x(f.at)}" cy="${y(f.vsTouchBps)}" r="4.5"/>`;
    const link = tx(f.txHash);
    parts.push(link ? `<a href="${link}" target="_blank" rel="noreferrer">${dot}</a>` : dot);
  });

  // The date axis: local midnights labelled, noons ticked.
  const axisY = PAD.top + CH;
  parts.push(`<line class="rc-grid" x1="${PAD.left}" y1="${axisY}" x2="${W - PAD.right}" y2="${axisY}"/>`);
  const firstMidnight = new Date(lo * 1000);
  firstMidnight.setHours(0, 0, 0, 0);
  for (let t = firstMidnight.getTime() / 1000 + 86400; t < hi; t += 43200) {
    const d = new Date(t * 1000);
    const midnight = d.getHours() === 0;
    parts.push(`<line class="rc-grid" x1="${x(t)}" y1="${axisY}" x2="${x(t)}" y2="${axisY + (midnight ? 6 : 3)}"/>`);
    if (midnight) {
      parts.push(`<text class="rc-lab" x="${x(t)}" y="${axisY + 18}" text-anchor="middle">${
        d.toLocaleDateString("en-US", { month: "short", day: "numeric" })
      }</text>`);
    }
  }

  // The spine: the book series, on the same axis. A solid segment with end caps, because the
  // file carries the series as an aggregate — count, span, median gap — and the drawing claims
  // no more than that. The moment the schema carries books.times, each poke gets its own tick.
  const spineY = axisY + DATES + 12;
  parts.push(`<line class="rc-spine-base" x1="${PAD.left}" y1="${spineY}" x2="${W - PAD.right}" y2="${spineY}"/>`);
  if (Number.isFinite(books.firstAt) && Number.isFinite(books.lastAt)) {
    const a = x(books.firstAt);
    const b = x(Math.max(books.lastAt, books.firstAt + 60));
    if (Array.isArray(books.times) && books.times.length) {
      for (const t of books.times) {
        parts.push(`<line class="rc-poke" x1="${x(t)}" y1="${spineY - 4}" x2="${x(t)}" y2="${spineY + 4}"/>`);
      }
    } else {
      parts.push(`<line class="rc-spine" x1="${a}" y1="${spineY}" x2="${b}" y2="${spineY}"/>`);
      parts.push(`<line class="rc-spine" x1="${a}" y1="${spineY - 4}" x2="${a}" y2="${spineY + 4}"/>`);
      parts.push(`<line class="rc-spine" x1="${b}" y1="${spineY - 4}" x2="${b}" y2="${spineY + 4}"/>`);
    }
    parts.push(`<text class="rc-lab" x="${a - 8}" y="${spineY + 3}" text-anchor="end">the book series — ${books.count ?? "—"} pokes · median gap ${books.medianGapSeconds ?? "—"} s</text>`);
  }

  ui.chart.innerHTML =
    `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="every fill the desk has signed against the book's touch, over days">${parts.join("")}</svg>`;

  // What the picture leaves out, said next to the picture. The fill stays in the artifact and in
  // the keeper's decision below — the exclusion is only about what the chart can claim.
  if (ui.excluded) {
    ui.excluded.innerHTML = excluded.map((f) => {
      const link = tx(f.txHash);
      const hash = link ? `<a href="${link}" target="_blank" rel="noreferrer">${short(f.txHash)}</a>` : short(f.txHash);
      return `Out of the chart by name: ${hash}, the <b>${escape(f.deskName)}</b> take that built ` +
        `the exposure the hedge then covered — priced from the reserves the strategy was shipped ` +
        `with (poolDev ${fmtDev(f.poolDevBps)} bps), not from a quote the bound held against the ` +
        `book. It stays in the file, and in the keeper's decision below.`;
    }).join(" ");
  }

  // Why the series exists, and why it is young. The framing is precise because the imprecise
  // version — "the only archive of the book" — is false: this is four words a minute, not the
  // book, and Hyperliquid publishes its own L2 archive. What nothing else reproduces is the join:
  // the same stream, the same clock, the fill and the book five, fifteen and sixty minutes later.
  const before = Number.isFinite(books.firstAt) ? allFills.filter((f) => f.at < books.firstAt).length : 0;
  // Two sentences up, the rest folded: the fact and the consequence carry the section on their
  // own; the numbers, the before-series count and the join are for whoever opens the fold.
  ui.why.innerHTML = Number.isFinite(books.firstAt)
    ? `The book this quote reads is not HyperEVM state: the precompiles answer with the present ` +
      `whatever block tag you ask for, and asking for the past returns the present without an ` +
      `error. A Substreams module can only stream what a contract logs, so the floor logs the book ` +
      `itself.`
    : "";
  if (ui.whyFull) {
    ui.whyFull.innerHTML = Number.isFinite(books.firstAt)
      ? `Permissionless, four words — bid, ask, mark, oracle — one poke a minute: ` +
        `<b>${books.count ?? "—"} pokes</b> so far, median gap ` +
        `${books.medianGapSeconds ?? "—"} s, started ${when(books.firstAt)}. That is why the record ` +
        `begins there, and why ${before} of the ${allFills.length} fills are marked <b>before the ` +
        `series</b> rather than given a number they cannot have. The same stream then joins each fill ` +
        `to the book five, fifteen and sixty minutes later — that join is what the series is for. It ` +
        `cannot be reconstructed from Hyperliquid's S3 archive or its WebSocket: another domain, ` +
        `another scale, another clock.`
      : "";
  }

  renderDecision(ui, doc, allFills, ledger, chain);

  // The markouts: post-fill drift, small n written as the count, every missing horizon named.
  // Not adverse selection — the flow is this repository's own, so there is no informed taker to
  // be selected against. They are here because each one exercises the keeper loop end to end.
  const horizons = doc.horizonsMinutes ?? Object.keys(sum.byHorizon ?? {}).map(Number);
  const cells = horizons.map((h) => {
    const st = sum.byHorizon?.[h];
    const n = st?.n ?? 0;
    let value = "—";
    if (n === 1) value = fmtBps(st.medianBps ?? st.meanBps);
    else if (n === 2) value = `${fmtBps(st.minBps)} · ${fmtBps(st.maxBps)}`;
    else if (n > 2) value = `${fmtBps(st.medianBps)} med · ${fmtBps(st.minBps)}…${fmtBps(st.maxBps)}`;
    const missing = ["beforeSeries", "pending", "gap", "noBook"]
      .filter((k) => (st?.[k] ?? 0) > 0)
      .map((k) => `${st[k]} ${MISSING[k]}`)
      .join(" · ");
    return (
      `<div class="record-mk">` +
      `<div class="record-mk-h">${h} min</div>` +
      `<div class="record-mk-v">${n ? `${value} bps · n=${n}` : `— · n=0`}</div>` +
      `<div class="record-mk-m">${missing || "all accounted for"}</div>` +
      `</div>`
    );
  });
  ui.markouts.innerHTML =
    `<p class="record-mk-sub">where the book went after each fill, signed from the desk's side, ` +
    `over ${sum.spanDays ?? "—"} days. This flow is sent by a schedule in this repository, so it ` +
    `carries no information and this is drift, not adverse selection and not an edge claim.</p>` +
    `<div class="record-mk-grid">${cells.join("")}</div>`;

  // The file's own freshness and provenance — saying what the artifact is costs zero. The desks
  // are named as they are in the file, all of them, with their counts: naming only the first
  // fill's desk while plotting the rest was the label lying about the picture.
  const age = Math.max(0, Math.round(now - (doc.generatedAt ?? now)));
  const byDesk = new Map();
  for (const f of allFills) byDesk.set(f.deskName, (byDesk.get(f.deskName) ?? 0) + 1);
  const desksLine = [...byDesk.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([name, n]) => `<b>${escape(name)}</b> ${n}`)
    .join(" · ");
  ui.foot.innerHTML =
    `generated <b>${ageText(age)}</b> · fills streamed by Substreams on The Graph Market (Pinax) · ` +
    `module ${escape(doc.source?.module ?? "—")} · blocks ${num(doc.source?.startBlock)}–${num(doc.source?.stopBlock)} · ` +
    `desks ${desksLine || "—"} · a mock pair · chain ${doc.chainId ?? "—"}`;
}

// The keeper's decision, made visible. The scatter is the price claim; this panel is the loop the
// claim runs on — every twenty minutes a keeper streams the same blocks, decides per fill and per
// horizon whether a markout exists, writes the ones that do to MarkoutLedger, and reads its own
// writes back out of the stream on the next pass. The rows keep every "no" beside every number,
// because the interesting thing an agent says is what it cannot measure, and why.
function renderDecision(ui, doc, fills, ledger, chain) {
  const node = ui.decision;
  if (!node) return;
  const books = doc.books ?? {};
  const horizons = doc.horizonsMinutes ?? [5, 15, 60];
  const posted = new Map((doc.postedThisRun ?? []).map((p) => [`${p.fillId}:${p.horizonMinutes}`, p]));
  const failed = doc.failedThisRun ?? [];
  const txl = (hash) => explorerTx(chain, hash);
  const addr = (a) => (chain.blockExplorers ? `${chain.blockExplorers.default.url}/address/${a}` : null);
  const now = Math.floor(Date.now() / 1000);
  const age = Math.max(0, Math.round(now - (doc.generatedAt ?? now)));

  const ledgerLink =
    ledger && addr(ledger)
      ? `<a href="${addr(ledger)}" target="_blank" rel="noreferrer">MarkoutLedger ${short(ledger)}</a>`
      : ledger
        ? `MarkoutLedger ${short(ledger)}`
        : "MarkoutLedger";

  // This run's writes, with the hashes. A write is the decision leaving the page and landing on
  // the chain — the one part of the loop a screenshot cannot fake, so it is linked, not said.
  const writes = (doc.postedThisRun ?? []).map((p) => {
    const link = txl(p.txHash);
    const hash = link ? `<a href="${link}" target="_blank" rel="noreferrer">${short(p.txHash)}</a>` : short(p.txHash);
    // The posted bps is the integer that reached the chain, so it is printed as one.
    const bps = `${p.bps > 0 ? "+" : p.bps < 0 ? "−" : ""}${Math.abs(p.bps)}`;
    return `${p.horizonMinutes}m ${bps} bps → ${hash}`;
  });
  const runLine = writes.length
    ? `wrote <b>${writes.length}</b> markout${writes.length === 1 ? "" : "s"} — ${writes.join(" · ")}`
    : `wrote nothing — every measured markout was already on the ledger`;
  const failedLine = failed.length
    ? ` · <b>${failed.length} failed</b> — ${failed.map((f) => escape(f.error ?? "?")).join(" · ")}`
    : "";

  // The reason for each absence, in the keeper's own terms. "pending" resolves itself; a gap, a
  // pre-series fill and a failed book read never do — the tooltips say which and by how much.
  const tipFor = (f, h, m) => {
    if (m.status === "ok")
      return `the book ${m.lagSeconds} s after the horizon (tolerance ${m.toleranceSeconds} s) · ` +
        `the ledger gets it rounded to ${Math.round(m.bps)} bps; this file keeps the unrounded value`;
    if (m.status === "pending")
      return `the series has not reached the fill's +${h}m mark yet — a pass that finds a book ` +
        `within ${m.toleranceSeconds} s of it writes the markout`;
    if (m.status === "gap")
      return `the first book after the horizon came ${m.nearestLagSeconds} s after it, past the ` +
        `${m.toleranceSeconds} s tolerance — a hole in the series; this markout never resolves`;
    if (m.status === "noBook")
      return `the fill's own book read failed, so there is no left-hand side — this markout never resolves`;
    return `the fill predates the first poke — there is no book to join it to, and there never will be`;
  };

  ui.currentHorizons = horizons;

  // The rows are one per fill, and the fill count grows every day the desks run, so the table
  // shows its most useful rows and folds the rest: the latest eight, the most recent fill with
  // every horizon resolved — the table's one worked example — and one from before the series, so
  // the absence the legend names is a row on the screen rather than only a description.
  const complete = (f) => horizons.every((h) => f.markouts?.[String(h)]?.status === "ok");
  const visible = new Set(fills.slice(-8).map((f) => f.fillId));
  const lastComplete = [...fills].reverse().find((f) => complete(f));
  if (lastComplete) visible.add(lastComplete.fillId);
  const preSeries = [...fills].reverse().find((f) => Number.isFinite(books.firstAt) && f.at < books.firstAt);
  if (preSeries) visible.add(preSeries.fillId);

  const rowFor = (f) => {
    const cells = horizons.map((h) => {
      const m = f.markouts?.[String(h)];
      if (!m) return `<div class="rd-cell rd-mut">—</div>`;
      if (m.status === "ok") {
        const p = posted.get(`${f.fillId}:${h}`);
        const link = p && txl(p.txHash)
          ? ` → <a href="${txl(p.txHash)}" target="_blank" rel="noreferrer">${short(p.txHash)}</a>`
          : "";
        return `<div class="rd-cell" title="${escape(tipFor(f, h, m))}">${fmtBps(m.bps)} bps${link}</div>`;
      }
      const text = m.status === "pending"
        ? `pending · ~${Math.max(1, Math.ceil(((f.at + h * 60) - (books.lastAt ?? f.at + h * 60)) / 60))} min`
        : (MISSING[m.status] ?? m.status);
      return `<div class="rd-cell rd-mut" title="${escape(tipFor(f, h, m))}">${text}</div>`;
    });
    const link = txl(f.txHash);
    const label = link ? `<a href="${link}" target="_blank" rel="noreferrer">${when(f.at)}</a>` : when(f.at);
    // "the book it read" is the archive's question with this fill's instant already in it — the
    // archive answers from the row instead of living loose at the bottom of the tab.
    return (
      `<div class="rd-row" data-fill="${f.txHash}">` +
      `<div class="rd-fill">${label} · <b>${f.makerBuysBase ? "bought" : "sold"}</b> · ` +
      `${fmtVs(f.vsTouchBps)} · <button class="linky rd-book" data-archive-at="${f.at}">the book it read ▸</button></div>` +
      cells.join("") +
      `</div>`
    );
  };

  node.innerHTML =
    `<div class="record-mk-head">the keeper's decision</div>` +
    `<p class="record-mk-sub">Every twenty minutes a keeper in this repository decides, per fill ` +
    `and per horizon, whether the markout exists — and writes the ones that do to ${ledgerLink}.</p>` +
    `<p class="rd-run">this run, <b>${ageText(age)}</b> — ${runLine}${failedLine}</p>` +
    `<p class="rd-legend"><b>pending</b> — the series has not reached the horizon yet; it resolves ` +
    `itself · <b>gap</b> — the book arrived past the tolerance; a hole, it never resolves · ` +
    `<b>before the series</b> — the fill predates the first poke · <b>no book</b> — the fill's own ` +
    `read failed</p>`;

  const head = `<div class="rd-head"><div>fill · bps vs the touch</div>${horizons.map((h) => `<div>${h} min</div>`).join("")}</div>`;
  const shown = fills.filter((f) => visible.has(f.fillId));
  const rest = fills.filter((f) => !visible.has(f.fillId));
  if (ui.decisionRows) ui.decisionRows.innerHTML = head + shown.map(rowFor).join("");
  if (ui.decisionTail) {
    ui.decisionTail.innerHTML = rest.map(rowFor).join("");
    const fold = ui.decisionTail.closest("details");
    if (fold) {
      fold.hidden = rest.length === 0;
      const summary = fold.querySelector("summary");
      if (summary) summary.textContent = `the other ${rest.length} fills, row by row`;
    }
  }
}

const MISSING = {
  beforeSeries: "before the series",
  pending: "pending",
  gap: "gap in the series",
  noBook: "no book",
};

// Hover on a dot: the fill's row, one line under the chart, without leaving the page — when it
// happened, which desk and side, where it printed against the touch, and where the book went
// after. The matching table row lights up if it is one of the visible ones, and "the book it
// read" asks the archive this fill's own instant.
function showHover(ui, f) {
  if (!ui.hover) return;
  const hs = ui.currentHorizons ?? [5, 15, 60];
  const marks = hs.map((h) => {
    const m = f.markouts?.[String(h)];
    if (!m) return `${h}m —`;
    return m.status === "ok" ? `${h}m ${fmtVs(m.bps)} bps` : `${h}m ${MISSING[m.status] ?? m.status}`;
  }).join(" · ");
  const amt = (Number(f.baseRaw) / 1e8).toLocaleString("en-US", { maximumFractionDigits: 5 });
  ui.hover.innerHTML =
    `<b>${when(f.at)}</b> · <b>${escape(f.deskName)}</b> ${f.makerBuysBase ? "bought" : "sold"} ` +
    `${amt} base · printed <b>${fmtVs(f.vsTouchBps)} bps</b> vs the touch` +
    `${f.bookOk === false ? " (its book read failed)" : ""} · ${marks} · ` +
    `<button class="linky" data-archive-at="${f.at}">the book it read ▸</button>`;
  ui.hover.hidden = false;
  ui.decisionRows?.querySelector(`[data-fill="${f.txHash}"]`)?.classList.add("rd-hl");
  ui.decisionTail?.querySelector(`[data-fill="${f.txHash}"]`)?.classList.add("rd-hl");
}

function hideHover(ui) {
  if (!ui.hover) return;
  ui.hover.hidden = true;
  ui.decisionRows?.querySelectorAll(".rd-hl").forEach((el) => el.classList.remove("rd-hl"));
  ui.decisionTail?.querySelectorAll(".rd-hl").forEach((el) => el.classList.remove("rd-hl"));
}

/** A signed bps figure, adverse in red, favorable in ink — a cost is coloured, a gain is not. */
const fmtBps = (v) =>
  !Number.isFinite(v) ? "—"
  : v < 0 ? `<span class="neg">−${Math.abs(v).toFixed(2)}</span>`
  : `<span>+${v.toFixed(2)}</span>`;

const fmtVs = (v) => `${v > 0 ? "+" : v < 0 ? "−" : ""}${Math.abs(v).toFixed(2)}`;
const fmtDev = (v) => `${v > 0 ? "+" : v < 0 ? "−" : ""}${Math.abs(Math.round(v)).toLocaleString("en-US")}`;
const fmtZone = (v) => (Number.isInteger(v) ? String(v) : v.toFixed(2));
const when = (t) =>
  new Date(t * 1000).toLocaleString("en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false });
const ageText = (s) =>
  s < 60 ? "just now"
  : s < 3600 ? `${Math.floor(s / 60)} min ago`
  : `${Math.floor(s / 3600)} h ${Math.round((s % 3600) / 60)} min ago`;
const num = (v) => (Number.isFinite(v) ? v.toLocaleString("en-US") : "—");
const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const escape = (s) => String(s).replace(/[<>&]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;" })[c]);
