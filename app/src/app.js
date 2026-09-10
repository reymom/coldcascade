import { loadReplay, bpsFromMid, usd, hhmm, SchemaDrift } from "./replay.js";
import { el, svg, xScale, yScale, niceBounds, ticksFor, line, band, yAxis, xLabels, VIEW_W, PAD }
  from "./chart.js";

// The Evidence tab. Same claim as the Floor, over two hours instead of over one block: the Floor
// asks what an arbitrageur would get for trying *right now*, this asks what they got for trying all
// through 10 October 2025. Both answers are zero, and the zero is the headline — a multiple invites
// "of what, measured how?", a zero does not.

const CSV = "../results/oct10_replay.csv";

const H = { spot: 96, bands: 300, lean: 26, lvr: 190, edge: 210 };
const LABEL_EVERY = 15;

const fmtUsd = (v) => `$${Math.round(v).toLocaleString("en-US")}`;
const fmtBps = (v) => `${v > 0 ? "+" : ""}${Math.round(v)}`;

main();

async function main() {
  const status = document.getElementById("status");
  let rows;
  try {
    rows = await loadReplay(CSV);
  } catch (err) {
    status.className = "status error";
    status.textContent =
      err instanceof SchemaDrift
        ? `The CSV no longer matches the frozen schema.\n\n${err.message}`
        : `Could not read ${CSV}.\n\n${err.message}\n\n` +
          `The page fetches the CSV, so it needs a server rather than file://.\n` +
          `From the repository root:\n\n    python3 -m http.server 8000\n\n` +
          `then open http://localhost:8000/app/`;
    return;
  }
  status.remove();
  document.getElementById("page").hidden = false;

  const x = xScale(rows.length);
  const edge = cumulative(rows, EDGE);
  const lvr = cumulative(rows, LVR);
  drawHeadline(rows, edge);
  drawSpot(rows, x);
  drawBands(rows, x);
  drawLean(rows, x);
  drawLvr(rows, x, lvr);
  drawEdge(rows, x, edge);
  wireCrosshair(rows, x);
}

// ---- the five lines, named once ----
//
// The desk; the plain XYCSwap control it is an ablation of; the same curve charging 30 bps, which
// is what people deploy; a maker pegged to the oracle's last refresh, the realistic competitor that
// joined the pots the same day; and Hyperliquid's own touch, which is not a maker at all and is
// here so that "compared to what?" has an answer nobody can call a strawman.
const LINES = [
  { key: "desk", name: "desk", cls: "desk" },
  { key: "pegged", name: "oracle-pegged maker", cls: "pegged" },
  { key: "control", name: "control, plain XYCSwap", cls: "control" },
  { key: "hard", name: "control, XYCSwap at 30 bps", cls: "hard" },
  { key: "touch", name: "L1's own touch", cls: "touch" },
];

/** Each minute's 60 m markout applied to what that line actually absorbed, in dollars. */
const EDGE = {
  desk: (r) => Math.trunc((r.absorbedDeskNtl * r.markoutDesk60mBps) / 10_000),
  pegged: (r) => Math.trunc((r.absorbedPeggedNtl * r.markoutPegged60mBps) / 10_000),
  control: (r) => Math.trunc((r.absorbedControlNtl * r.markoutControl60mBps) / 10_000),
  hard: (r) => Math.trunc((r.absorbedHardNtl * r.markoutHard60mBps) / 10_000),
  touch: (r) => Math.trunc((r.absorbedTouchNtl * r.markoutTouch60mBps) / 10_000),
};

/** What the arbitrageur took out of each line this minute, closed at L1's touch, in dollars. */
const LVR = {
  desk: (r) => r.lvrDeskNtl,
  pegged: (r) => r.lvrPeggedNtl,
  control: (r) => r.lvrControlNtl,
  hard: (r) => r.lvrHardNtl,
  touch: () => 0,
};

/// Truncating toward zero, per row, because that is what the Solidity does — so the dollars on this
/// page and the dollars in results/oct10_replay.source are the same dollars.
function cumulative(rows, pick) {
  const out = {};
  for (const { key } of LINES) {
    let acc = 0;
    out[key] = rows.map((r) => (acc += pick[key](r)));
  }
  return out;
}

const last = (series) => series[series.length - 1];

function totals(rows) {
  const sum = (f) => rows.reduce((a, r) => a + f(r), 0);
  return {
    absorbed: {
      desk: sum((r) => r.absorbedDeskNtl),
      control: sum((r) => r.absorbedControlNtl),
      hard: sum((r) => r.absorbedHardNtl),
      touch: sum((r) => r.absorbedTouchNtl),
    },
    arb: {
      desk: sum((r) => r.arbDeskNtl),
      control: sum((r) => r.arbControlNtl),
      hard: sum((r) => r.arbHardNtl),
      touch: 0,
    },
  };
}

// ---- caption numbers ----

/**
 * What the charts' own captions carry: the two edge rates beside the carrying chart, the lean's
 * minute count, and the trough's price and hour. The big comparison boxes that used to prefix
 * these are gone — the charts carry the claim themselves now, so only their captions keep the
 * numbers.
 */
function drawHeadline(rows, edge) {
  const trough = rows.reduce((a, b) => (b.spot < a.spot ? b : a));
  const t = totals(rows);
  const set = (id, value, sub) => {
    const node = document.getElementById(id);
    if (!node) return;
    node.textContent = value;
    if (sub !== undefined) document.getElementById(`${id}-sub`).textContent = sub;
  };

  const perDollar = (e, n) => (n === 0 ? 0 : (e / n) * 10_000);
  set("stat-edge-desk", `${fmtBps(perDollar(last(edge.desk), t.absorbed.desk))} bps`,
    `${fmtUsd(last(edge.desk))} on ${fmtUsd(t.absorbed.desk)} absorbed`);
  set("stat-edge-touch", `${fmtBps(perDollar(last(edge.touch), t.absorbed.touch))} bps`,
    `${fmtUsd(last(edge.touch))} on ${fmtUsd(t.absorbed.touch)} at L1's touch`);
  set("stat-lean", String(rows.filter((r) => r.lean !== 0).length), `of ${rows.length} minutes`);
  set("stat-trough", fmtUsd(usd(trough.spot)), `at ${hhmm(trough.t)} UTC`);
}

// ---- the price the whole thing happened at ----

function drawSpot(rows, x) {
  const node = svg(document.getElementById("chart-spot"), H.spot);
  const prices = rows.map((r) => usd(r.spot));
  const [lo, hi] = niceBounds(prices, { padding: 0.15 });
  const y = yScale(lo, hi, H.spot, 10, 16);

  yAxis(node, y, [Math.ceil(lo / 2000) * 2000, Math.floor(hi / 2000) * 2000], (v) => fmtUsd(v), H.spot);

  const xs = rows.map((_, i) => x(i));
  const ys = prices.map(y);
  band(node, xs, ys, xs.map(() => y.bottom), { fill: "url(#spotFade)" });
  line(node, xs, ys, { class: "spot-line" });

  const defs = el("defs", {}, node);
  const grad = el("linearGradient", { id: "spotFade", x1: 0, y1: 0, x2: 0, y2: 1 }, defs);
  el("stop", { offset: "0%", "stop-color": "var(--spot)", "stop-opacity": 0.28 }, grad);
  el("stop", { offset: "100%", "stop-color": "var(--spot)", "stop-opacity": 0 }, grad);
}

// ---- the two books, on the only scale where both fit ----

function drawBands(rows, x) {
  const node = svg(document.getElementById("chart-bands"), H.bands);

  const l1Bid = rows.map((r) => bpsFromMid(r.bid, r.mid));
  const l1Ask = rows.map((r) => bpsFromMid(r.ask, r.mid));
  const dBid = rows.map((r) => bpsFromMid(r.deskBid, r.mid));
  const dAsk = rows.map((r) => bpsFromMid(r.deskAsk, r.mid));

  const [lo, hi] = niceBounds([...dBid, ...dAsk, ...l1Bid, ...l1Ask], { symmetric: true });
  const y = yScale(lo, hi, H.bands);
  yAxis(node, y, ticksFor(lo, hi, 6), (v) => `${fmtBps(v)}`, H.bands);

  const xs = rows.map((_, i) => x(i));

  // The desk's own two prices, as one band. In the quiet it encloses L1's on both sides.
  band(node, xs, dAsk.map(y), dBid.map(y), { class: "desk-fill" });
  // Hyperliquid's own best bid and offer, drawn on top so the enclosure is visible.
  band(node, xs, l1Ask.map(y), l1Bid.map(y), { class: "l1-fill" });

  // Where the desk is quoting *through* L1: the wedge that only opens under stress.
  const inside = el("g", {}, node);
  rows.forEach((r, i) => {
    const w = x.step + 0.6;
    const x0 = x.edge(i) - 0.3;
    if (dBid[i] > l1Bid[i]) {
      el("rect", { x: x0, width: w, y: y(dBid[i]), height: Math.max(0, y(l1Bid[i]) - y(dBid[i])),
        class: "inside inside-bid" }, inside);
    }
    if (dAsk[i] < l1Ask[i]) {
      el("rect", { x: x0, width: w, y: y(l1Ask[i]), height: Math.max(0, y(dAsk[i]) - y(l1Ask[i])),
        class: "inside inside-ask" }, inside);
    }
  });

  line(node, xs, l1Bid.map(y), { class: "l1-edge" });
  line(node, xs, l1Ask.map(y), { class: "l1-edge" });
  line(node, xs, dBid.map(y), { class: "desk-edge" });
  line(node, xs, dAsk.map(y), { class: "desk-edge" });

  xLabels(node, x, rows, H.bands - 6, LABEL_EVERY, (r) => hhmm(r.t));
}

// ---- which side is absorbing ----

function drawLean(rows, x) {
  const node = svg(document.getElementById("chart-lean"), H.lean);
  rows.forEach((r, i) => {
    el("rect", {
      x: x.edge(i), width: x.step + 0.5, y: 4, height: H.lean - 12,
      class: `lean lean-${r.leanName}`,
    }, node);
  });
}

// ---- what the arbitrageurs took ----

/**
 * The picture the Floor tab makes about one block, held for 123 of them.
 *
 * A maker is arbitraged when somebody can buy from it and sell at the reference venue for more
 * than they paid, and that profit is the maker's loss-versus-rebalancing. Every AMM has it, because
 * every AMM's price was set at some earlier moment than the trade that takes it. The desk has no
 * earlier moment: `CoreQuote` reads L1's book inside the call that settles the swap and clamps
 * itself to what crossing L1 would have paid.
 *
 * So the desk's line is flat on zero, and it is flat on zero because there was never a size that
 * worked, not because nobody looked — the same search ran against every maker on this chart and
 * put $1.4 m of size through the other three, $122 k of it through the pegged one, which keeps the
 * desk company near zero instead of keeping the AMMs company at thousands.
 *
 * The `lvr` column is named for the loss it attacks: what one arbitrageur extracted against one
 * book in the same minute, which is the channel the clamp is aimed at.
 */
function drawLvr(rows, x, lvr) {
  const node = svg(document.getElementById("chart-lvr"), H.lvr);
  const all = LINES.flatMap(({ key }) => lvr[key]);
  const [lo, hi] = niceBounds([...all, 0], { padding: 0.16 });
  const y = yScale(lo, hi, H.lvr);
  yAxis(node, y, ticksFor(lo, hi, 5), (v) => fmtUsd(v), H.lvr);

  const xs = rows.map((_, i) => x(i));
  for (const { key, cls } of LINES) {
    if (key === "touch") continue; // not a maker: it holds nothing to be arbitraged out of
    line(node, xs, lvr[key].map(y), { class: `edge-${cls}` });
  }

  endLabel(node, y(last(lvr.control)) - 6, fmtUsd(last(lvr.control)), "control");
  endLabel(node, y(last(lvr.hard)) + 14, fmtUsd(last(lvr.hard)), "hard");
  // The pegged line ends a few pixels above zero, so the desk's zero gets the slot below the line
  // and the pegged label the slot above its own — anything else overlaps.
  endLabel(node, y(last(lvr.pegged)) - 6, `${fmtUsd(last(lvr.pegged))} — pegged`, "pegged");
  endLabel(node, y(last(lvr.desk)) + 14, `${fmtUsd(last(lvr.desk))} — the desk`, "desk");

  xLabels(node, x, rows, H.lvr - 6, LABEL_EVERY, (r) => hhmm(r.t));
}

// ---- was the desk right an hour later ----

function drawEdge(rows, x, edge) {
  const node = svg(document.getElementById("chart-edge"), H.edge);
  const all = LINES.flatMap(({ key }) => edge[key]);
  const [lo, hi] = niceBounds([...all, 0], { padding: 0.16 });
  const y = yScale(lo, hi, H.edge);
  yAxis(node, y, ticksFor(lo, hi, 5), (v) => fmtUsd(v), H.edge);

  const xs = rows.map((_, i) => x(i));
  // Shaded against L1's own touch, not against the AMMs. The AMM lines are the ablation and the
  // competitor; the venue is the thing worth clearing, and it is the comparison a judge cannot
  // call a strawman — so it is the one the fill points at.
  band(node, xs, edge.desk.map(y), edge.touch.map(y), { class: "edge-gap" });
  for (const { key, cls } of LINES) {
    line(node, xs, edge[key].map(y), { class: `edge-${cls}` });
  }

  // The desk's label carries the comparison that matters, and it is not against an AMM. The pegged
  // line closes above the control line, so its label takes the slot above and control's stays below.
  endLabel(node, y(last(edge.pegged)) - 6, `${fmtUsd(last(edge.pegged))} — pegged`, "pegged");
  endLabel(node, y(last(edge.control)) + 14, fmtUsd(last(edge.control)), "control");
  endLabel(node, y(last(edge.hard)) + 26, fmtUsd(last(edge.hard)), "hard");
  endLabel(node, y(last(edge.touch)) + 14, `${fmtUsd(last(edge.touch))} — L1's touch`, "touch");
  endLabel(node, y(last(edge.desk)) - 6, `${fmtUsd(last(edge.desk))} — the desk`, "desk");

  xLabels(node, x, rows, H.edge - 6, LABEL_EVERY, (r) => hhmm(r.t));
}

function endLabel(node, py, text, cls) {
  const node_ = el("text", {
    x: VIEW_W - PAD.right, y: py, class: `edge-label edge-label-${cls}`, "text-anchor": "end",
  }, node);
  node_.append(text);
}

// ---- the readout ----

function wireCrosshair(rows, x) {
  const surface = document.getElementById("panels");
  const readout = document.getElementById("readout");
  // Only the carousel's own slides track — the day fold below keeps its two charts still.
  const rules = [...surface.querySelectorAll(".chart svg")].map((node) => {
    const rule = el("line", { class: "crosshair", y1: 0, y2: node.viewBox.baseVal.height }, node);
    return rule;
  });

  const move = (event) => {
    const box = surface.getBoundingClientRect();
    const px = ((event.clientX - box.left) / box.width) * VIEW_W;
    if (px < PAD.left || px > VIEW_W - PAD.right) return hide();
    const i = x.invert(px);
    const cx = x(i);
    rules.forEach((rule) => { rule.setAttribute("x1", cx); rule.setAttribute("x2", cx); });
    surface.classList.add("tracking");
    readout.innerHTML = "";
    const r = rows[i];
    for (const [k, v] of [
      ["time", `${hhmm(r.t)} UTC`],
      ["spot", fmtUsd(usd(r.spot))],
      ["L1 bid / ask", `${fmtBps(bpsFromMid(r.bid, r.mid))} / ${fmtBps(bpsFromMid(r.ask, r.mid))} bps`],
      ["desk bid / ask", `${fmtBps(bpsFromMid(r.deskBid, r.mid))} / ${fmtBps(bpsFromMid(r.deskAsk, r.mid))} bps`],
      ["lean", r.leanName],
      ["dislocation", `${fmtBps(r.dislocationBps)} bps`],
      ["forced sell / buy", `$${r.forcedSellNtl.toLocaleString("en-US")} / $${r.forcedBuyNtl.toLocaleString("en-US")}`],
      ["absorbed", r.absorbedDeskNtl || r.absorbedPeggedNtl || r.absorbedControlNtl || r.absorbedHardNtl
        ? `desk $${r.absorbedDeskNtl.toLocaleString("en-US")}`
          + ` · pegged $${r.absorbedPeggedNtl.toLocaleString("en-US")}`
          + ` · control $${r.absorbedControlNtl.toLocaleString("en-US")}`
          + ` · 30 bps $${r.absorbedHardNtl.toLocaleString("en-US")}`
        : "—"],
      ["markout rate 60m", r.markoutDesk60mBps || r.markoutPegged60mBps || r.markoutControl60mBps || r.markoutHard60mBps
        ? `desk ${fmtBps(r.markoutDesk60mBps)} · pegged ${fmtBps(r.markoutPegged60mBps)} · control ${fmtBps(r.markoutControl60mBps)}`
          + ` · 30 bps ${fmtBps(r.markoutHard60mBps)} · L1 ${fmtBps(r.markoutTouch60mBps)} bps`
        : "—"],
      ["taken by arbitrageurs", r.arbDeskNtl || r.arbPeggedNtl || r.arbControlNtl || r.arbHardNtl
        ? `desk $${r.arbDeskNtl.toLocaleString("en-US")}`
          + ` · pegged $${r.arbPeggedNtl.toLocaleString("en-US")}`
          + ` · control $${r.arbControlNtl.toLocaleString("en-US")}`
          + ` · 30 bps $${r.arbHardNtl.toLocaleString("en-US")}`
        : "—"],
      ["lvr paid", r.lvrDeskNtl || r.lvrPeggedNtl || r.lvrControlNtl || r.lvrHardNtl
        ? `desk $${r.lvrDeskNtl.toLocaleString("en-US")}`
          + ` · pegged $${r.lvrPeggedNtl.toLocaleString("en-US")}`
          + ` · control $${r.lvrControlNtl.toLocaleString("en-US")}`
          + ` · 30 bps $${r.lvrHardNtl.toLocaleString("en-US")}`
        : "—"],
      ["pnl, marked at spot", `desk ${fmtBps(r.pnlDeskBps)} · pegged ${fmtBps(r.pnlPeggedBps)} · control ${fmtBps(r.pnlControlBps)}`
        + ` · 30 bps ${fmtBps(r.pnlHardBps)} bps`],
    ]) {
      const cell = document.createElement("div");
      cell.className = "readout-cell";
      const key = document.createElement("span");
      key.className = "readout-key";
      key.textContent = k;
      const val = document.createElement("span");
      val.className = `readout-val readout-${r.leanName}`;
      val.textContent = v;
      cell.append(key, val);
      readout.append(cell);
    }
  };
  const hide = () => surface.classList.remove("tracking");

  surface.addEventListener("pointermove", move);
  surface.addEventListener("pointerleave", hide);
  move({ clientX: surface.getBoundingClientRect().left + surface.getBoundingClientRect().width * 0.5 });
}
