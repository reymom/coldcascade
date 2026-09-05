import { loadReplay, bpsFromMid, usd, hhmm, SchemaDrift } from "./replay.js";
import { el, svg, xScale, yScale, niceBounds, ticksFor, line, band, yAxis, xLabels, VIEW_W, PAD }
  from "./chart.js";

const CSV = "../results/oct10_replay.csv";

const H = { spot: 96, bands: 300, lean: 26, edge: 210 };
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
  const edge = absorbedEdge(rows);
  drawHeadline(rows, edge);
  drawSpot(rows, x);
  drawBands(rows, x);
  drawLean(rows, x);
  drawEdge(rows, x, edge);
  wireCrosshair(rows, x);
}

// ---- headline ----

function drawHeadline(rows, edge) {
  const trough = rows.reduce((a, b) => (b.spot < a.spot ? b : a));
  const deskTotal = edge.desk[edge.desk.length - 1];
  const controlTotal = edge.control[edge.control.length - 1];
  const set = (id, value, sub) => {
    document.getElementById(id).textContent = value;
    if (sub) document.getElementById(`${id}-sub`).textContent = sub;
  };
  set("stat-desk", fmtUsd(deskTotal), "absorbed, marked out at 60m");
  set("stat-control", fmtUsd(controlTotal), "plain XYCSwap, same tape");
  set("stat-multiple", controlTotal > 0 ? `${(deskTotal / controlTotal).toFixed(1)}x` : "—",
    "desk over control");
  set("stat-lean", String(rows.filter((r) => r.lean !== 0).length), `of ${rows.length} minutes`);
  set("stat-trough", fmtUsd(usd(trough.spot)), `at ${hhmm(trough.t)} UTC`);
}

/// The quantity the argument rests on. A markout in bps is a rate, and the desk is meant to lose
/// on that rate: leaning inside the spread is paying up, on every fill, by construction. What it
/// buys with that is size at a price that reverts, so the number that matters is the rate applied
/// to the notional it actually absorbed, run forward over the session.
function absorbedEdge(rows) {
  let d = 0;
  let c = 0;
  const desk = [];
  const control = [];
  for (const r of rows) {
    d += (r.markoutDesk60mBps / 10_000) * r.absorbedDeskNtl;
    c += (r.markoutControl60mBps / 10_000) * r.absorbedControlNtl;
    desk.push(d);
    control.push(c);
  }
  return { desk, control };
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

// ---- was the desk right an hour later ----

function drawEdge(rows, x, edge) {
  const node = svg(document.getElementById("chart-edge"), H.edge);
  const [lo, hi] = niceBounds([...edge.desk, ...edge.control, 0], { padding: 0.16 });
  const y = yScale(lo, hi, H.edge);
  yAxis(node, y, ticksFor(lo, hi, 5), (v) => fmtUsd(v), H.edge);

  const xs = rows.map((_, i) => x(i));
  const deskY = edge.desk.map(y);
  const controlY = edge.control.map(y);

  band(node, xs, deskY, controlY, { class: "edge-gap" });
  line(node, xs, controlY, { class: "edge-control" });
  line(node, xs, deskY, { class: "edge-desk" });

  const label = (value, py, cls) => {
    const text = el("text", { x: VIEW_W - PAD.right, y: py - 6, class: `edge-label ${cls}`,
      "text-anchor": "end" }, node);
    text.append(fmtUsd(value));
  };
  label(edge.desk.at(-1), deskY.at(-1), "edge-label-desk");
  label(edge.control.at(-1), controlY.at(-1) + 18, "edge-label-control");

  xLabels(node, x, rows, H.edge - 6, LABEL_EVERY, (r) => hhmm(r.t));
}

// ---- the readout ----

function wireCrosshair(rows, x) {
  const surface = document.getElementById("panels");
  const readout = document.getElementById("readout");
  const rules = [...document.querySelectorAll(".chart svg")].map((node) => {
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
      ["absorbed", r.absorbedDeskNtl || r.absorbedControlNtl
        ? `desk $${r.absorbedDeskNtl.toLocaleString("en-US")} · control $${r.absorbedControlNtl.toLocaleString("en-US")}`
        : "—"],
      ["markout rate 60m", r.markoutDesk60mBps || r.markoutControl60mBps
        ? `desk ${fmtBps(r.markoutDesk60mBps)} · control ${fmtBps(r.markoutControl60mBps)} bps`
        : "—"],
      ["pnl, marked at spot", `desk ${fmtBps(r.pnlDeskBps)} · control ${fmtBps(r.pnlControlBps)} bps`],
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
