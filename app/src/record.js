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
// itself once a minute, because HyperCore's precompiles ignore the block tag and there is no
// archive to read back — which is why the record starts when the series starts, and why fills
// before it are marked "before the series" rather than given a number they cannot have.

import { chainFor, explorerTx } from "./signer.js";

const FILE = "../results/markouts.json";
const POLL_MS = 60_000;

const W = 1000;
const PAD = { left: 66, right: 14, top: 34 };
const CH = 240;   // the chart's height
const DATES = 26; // the date axis row
const SPINE = 34; // the book-series row

export async function mountRecord(root) {
  const ui = {
    chart: root.querySelector("#record-chart"),
    why: root.querySelector("#record-why"),
    markouts: root.querySelector("#record-markouts"),
    foot: root.querySelector("#record-foot"),
    status: root.querySelector("#record-status"),
  };
  if (!ui.chart) return;

  const tick = async () => {
    try {
      const res = await fetch(FILE, { cache: "no-store" });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      render(ui, await res.json());
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

function render(ui, doc) {
  const fills = (doc.fills ?? []).filter((f) => Number.isFinite(f.vsTouchBps) && Number.isFinite(f.at));
  const books = doc.books ?? {};
  const sum = doc.summary ?? {};
  const tx = (hash) => explorerTx(chainFor(doc.chainId ?? 999, ""), hash);

  // The dead zone's half-width is the mechanism's bound: quietBps, 20 on every desk on the
  // floor, and the record pins exactly there. The file does not carry the parameter, so the band
  // is the shipped bound and nothing else — the day a fill lands at ±15 the honest picture is a
  // dot inside the band and a mechanism to look at, not a band that quietly redrew itself around
  // it. If the schema grows a quietBps field, it wins.
  const zone = Number.isFinite(doc.quietBps) ? doc.quietBps : 20;

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
  parts.push(`<text class="rc-lab" x="${PAD.left + 10}" y="${y(zone) + 13}">the dead zone — no fill lands inside ±${fmtZone(zone)} bps of the touch</text>`);

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

  // The fills. Amber the desk bought base, teal it sold; each links to its own transaction.
  for (const f of fills) {
    const side = f.makerBuysBase ? "buy" : "sell";
    const cls = `rc-dot rc-${side}${f.bookOk === false ? " rc-nobook" : ""}`;
    const tip =
      `${when(f.at)} · the desk ${f.makerBuysBase ? "bought" : "sold"} base · ` +
      `${fmtVs(f.vsTouchBps)} bps vs the touch${f.bookOk === false ? " · the book read failed" : ""} · ${f.txHash.slice(0, 10)}…`;
    const dot = `<circle class="${cls}" cx="${x(f.at)}" cy="${y(f.vsTouchBps)}" r="4.5"><title>${escape(tip)}</title></circle>`;
    const link = tx(f.txHash);
    parts.push(link ? `<a href="${link}" target="_blank" rel="noreferrer">${dot}</a>` : dot);
  }

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

  // Why the series exists, and why it is young. The count of pre-series fills is computed, not
  // repeated — it is the beforeSeries number the markout row shows, said where the spine is.
  const before = Number.isFinite(books.firstAt) ? fills.filter((f) => f.at < books.firstAt).length : 0;
  ui.why.innerHTML = Number.isFinite(books.firstAt)
    ? `HyperCore's precompiles ignore the block tag, so there is no archive of this book to read ` +
      `back — the floor writes its own, one poke every 60 seconds: <b>${books.count ?? "—"} pokes</b> ` +
      `so far, median gap ${books.medianGapSeconds ?? "—"} s, started ${when(books.firstAt)}. That is ` +
      `why the record begins there, and why ${before} of the ${fills.length} fills are marked ` +
      `<b>before the series</b> instead of given a number they cannot have.`
    : "";

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
    `<div class="record-mk-head">post-fill drift</div>` +
    `<p class="record-mk-sub">where the book went after each fill, signed from the desk's side, ` +
    `over ${sum.spanDays ?? "—"} days. This flow is sent by a schedule in this repository, so it ` +
    `carries no information and this is drift, not adverse selection and not an edge claim — ` +
    `what it demonstrates is the loop: stream, join, decide, write to chain, read the decision back.</p>` +
    `<div class="record-mk-grid">${cells.join("")}</div>`;

  // The file's own freshness and provenance — saying what the artifact is costs zero.
  const age = Math.max(0, Math.round(now - (doc.generatedAt ?? now)));
  const deskName = fills[0]?.deskName ?? "—";
  const deskAddr = fills[0]?.desk ? short(fills[0].desk) : "";
  ui.foot.innerHTML =
    `generated <b>${ageText(age)}</b> · fills streamed by Substreams on The Graph Market (Pinax) · ` +
    `module ${escape(doc.source?.module ?? "—")} · blocks ${num(doc.source?.startBlock)}–${num(doc.source?.stopBlock)} · ` +
    `desk <b>${escape(deskName)}</b>${deskAddr ? ` ${deskAddr}` : ""} · a mock pair · chain ${doc.chainId ?? "—"}`;
}

const MISSING = {
  beforeSeries: "before the series",
  pending: "pending",
  gap: "gap in the series",
  noBook: "no book",
};

/** A signed bps figure, adverse in red, favorable in ink — a cost is coloured, a gain is not. */
const fmtBps = (v) =>
  !Number.isFinite(v) ? "—"
  : v < 0 ? `<span class="neg">−${Math.abs(v).toFixed(2)}</span>`
  : `<span>+${v.toFixed(2)}</span>`;

const fmtVs = (v) => `${v > 0 ? "+" : v < 0 ? "−" : ""}${Math.abs(v).toFixed(2)}`;
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
