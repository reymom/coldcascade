import { loadReplay, bpsFromMid, usd, hhmm, SchemaDrift } from "./replay.js";
import { el, svg, xScale, yScale, niceBounds, ticksFor, line, band, yAxis, xLabels, VIEW_W, PAD }
  from "./chart.js";

const CSV = "../results/oct10_replay.csv";

const H = { spot: 96, bands: 300, lean: 26, markout: 210 };
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
  drawHeadline(rows);
  drawSpot(rows, x);
  drawBands(rows, x);
  drawLean(rows, x);
  drawMarkouts(rows, x);
  wireCrosshair(rows, x);
}

// ---- headline ----

function drawHeadline(rows) {
  const last = rows[rows.length - 1];
  const trough = rows.reduce((a, b) => (b.spot < a.spot ? b : a));
  const set = (id, value, sub) => {
    document.getElementById(id).textContent = value;
    if (sub) document.getElementById(`${id}-sub`).textContent = sub;
  };
  set("stat-desk", fmtBps(last.pnlDeskBps), "bps, marked at spot");
  set("stat-control", fmtBps(last.pnlControlBps), "bps, plain XYCSwap");
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

// ---- was the desk right an hour later ----

function drawMarkouts(rows, x) {
  const node = svg(document.getElementById("chart-markout"), H.markout);
  const filled = rows
    .map((r, i) => ({ r, i }))
    .filter(({ r }) => r.markoutDesk60mBps !== 0 || r.markoutControl60mBps !== 0);

  if (filled.length === 0) {
    el("text", { x: VIEW_W / 2, y: H.markout / 2, class: "empty", "text-anchor": "middle" }, node)
      .append("no fill on this tape carries a 60 minute markout");
    return;
  }

  const values = filled.flatMap(({ r }) => [r.markoutDesk60mBps, r.markoutControl60mBps, 0]);
  const [lo, hi] = niceBounds(values, { padding: 0.18 });
  const y = yScale(lo, hi, H.markout);
  yAxis(node, y, ticksFor(lo, hi, 5), (v) => fmtBps(v), H.markout);

  // The control sits behind and wider, the desk in front and narrower. The two agree to within
  // twenty bps on this tape, and a side-by-side pair would read as one bar; nested, both are
  // always visible and the difference is the collar.
  const zero = y(0);
  const wide = Math.max(4, Math.min(14, x.step * 0.8));
  const narrow = wide * 0.5;
  for (const { r, i } of filled) {
    for (const [value, cls, w] of [
      [r.markoutControl60mBps, "bar-control", wide],
      [r.markoutDesk60mBps, "bar-desk", narrow],
    ]) {
      const py = y(value);
      el("rect", {
        x: x(i) - w / 2, width: w,
        y: Math.min(py, zero), height: Math.max(1.5, Math.abs(py - zero)),
        class: `bar ${cls}`,
      }, node);
    }
  }
  xLabels(node, x, rows, H.markout - 6, LABEL_EVERY, (r) => hhmm(r.t));
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
      ["markout 60m", r.markoutDesk60mBps || r.markoutControl60mBps
        ? `desk ${fmtBps(r.markoutDesk60mBps)} · control ${fmtBps(r.markoutControl60mBps)}`
        : "—"],
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
