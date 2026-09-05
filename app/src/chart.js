// Enough SVG to draw four series and a strip. No library: the page has three charts and they all
// share one x axis, which is less code than configuring something.

const NS = "http://www.w3.org/2000/svg";

export const el = (name, attrs = {}, parent = null) => {
  const node = document.createElementNS(NS, name);
  for (const [k, v] of Object.entries(attrs)) {
    if (v !== null && v !== undefined) node.setAttribute(k, String(v));
  }
  if (parent) parent.appendChild(node);
  return node;
};

export const VIEW_W = 1200;
export const PAD = { left: 62, right: 16, top: 12, bottom: 4 };

export function svg(host, height) {
  host.replaceChildren();
  const node = el("svg", {
    viewBox: `0 0 ${VIEW_W} ${height}`,
    preserveAspectRatio: "none",
    role: "img",
  }, host);
  return node;
}

/** index -> px. One column per minute, plotted at the centre of its slot. */
export function xScale(n) {
  const w = VIEW_W - PAD.left - PAD.right;
  const step = w / n;
  const at = (i) => PAD.left + (i + 0.5) * step;
  at.step = step;
  at.edge = (i) => PAD.left + i * step;
  at.invert = (px) => Math.min(n - 1, Math.max(0, Math.floor((px - PAD.left) / step)));
  return at;
}

/** value -> px, top-down. */
export function yScale(min, max, height, padTop = PAD.top, padBottom = 22) {
  const span = max - min || 1;
  const h = height - padTop - padBottom;
  const at = (v) => padTop + h - ((v - min) / span) * h;
  at.min = min;
  at.max = max;
  at.bottom = padTop + h;
  return at;
}

export function niceBounds(values, { symmetric = false, padding = 0.12 } = {}) {
  let lo = Math.min(...values);
  let hi = Math.max(...values);
  if (symmetric) {
    const m = Math.max(Math.abs(lo), Math.abs(hi));
    lo = -m;
    hi = m;
  }
  const pad = (hi - lo || 1) * padding;
  return [lo - pad, hi + pad];
}

export function line(parent, xs, ys, attrs) {
  const d = xs.map((x, i) => `${i ? "L" : "M"}${x.toFixed(2)} ${ys[i].toFixed(2)}`).join("");
  return el("path", { d, fill: "none", ...attrs }, parent);
}

/** The area between two series, as one closed path: top edge left to right, bottom edge back. */
export function band(parent, xs, top, bottom, attrs) {
  const forward = xs.map((x, i) => `${i ? "L" : "M"}${x.toFixed(2)} ${top[i].toFixed(2)}`).join("");
  const back = xs
    .map((x, i) => [x, bottom[i]])
    .reverse()
    .map(([x, y]) => `L${x.toFixed(2)} ${y.toFixed(2)}`)
    .join("");
  return el("path", { d: `${forward}${back}Z`, stroke: "none", ...attrs }, parent);
}

export function yAxis(parent, y, ticks, format, height) {
  const g = el("g", { class: "axis" }, parent);
  for (const v of ticks) {
    const py = y(v);
    if (py < PAD.top - 1 || py > y.bottom + 1) continue;
    el("line", {
      x1: PAD.left, x2: VIEW_W - PAD.right, y1: py, y2: py,
      class: v === 0 ? "grid grid-zero" : "grid",
    }, g);
    el("text", { x: PAD.left - 8, y: py + 3.5, class: "tick", "text-anchor": "end" }, g)
      .append(format(v));
  }
  return g;
}

export function ticksFor(lo, hi, count = 5) {
  const raw = (hi - lo) / count;
  const mag = 10 ** Math.floor(Math.log10(Math.abs(raw) || 1));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw) ?? mag * 10;
  const out = [];
  for (let v = Math.ceil(lo / step) * step; v <= hi; v += step) out.push(Math.abs(v) < step / 1e6 ? 0 : v);
  return out;
}

export function xLabels(parent, x, rows, y, every, label) {
  const g = el("g", { class: "axis" }, parent);
  rows.forEach((row, i) => {
    if (i % every !== 0) return;
    el("text", { x: x(i), y, class: "tick", "text-anchor": "middle" }, g).append(label(row));
  });
  return g;
}
