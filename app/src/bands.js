// The thesis in one drawing: the desk's band against a flat curve's, over the book's own.
//
// One axis — basis points from the book's mid, the only scale on which a 20 bps quote and an
// $80 000 price fit on one screen. Three rows: the book's own bid–ask as a grey band that never
// moves; one desk's band, outside it on both sides in the quiet; and where a plain constant-
// product curve on the SAME reserves would trade instead — a single price, not a band, drawn as
// a red tick. The distance from that tick to the grey band is the toll the arbitrage search
// collects every block: it is the number beside the zero, drawn.
//
// One desk stands for the strip because the three quote from the same book with the same rule —
// the row of bands was the drawing of a constant. What differs between desks (inventory, cover,
// margin) is a property of accounts, and it lives in the table below. The desk shown is a
// leaning one when any leans — the lean is the show — and otherwise the one whose flat curve
// sits furthest from the book, which is the desk the toll is counted on.
//
// When the shown desk leans, the quiet machinery returns: the wedge where its band crosses
// inside the book's, the ghost outline where it sits when it is not leaning, and the travel —
// because the wedge is capped at the book's own price and is often sub-pixel, while the move is
// twenty basis points in one tick. Both are drawn; the move is the point.

const W = 1000;
const ROW = 32;
const PAD = { top: 18, bottom: 26, left: 8, right: 8 };

export function drawStrip(host, book, desks) {
  const mid = (Number(book.bid) + Number(book.ask)) / 2;
  if (!Number.isFinite(mid) || mid === 0) return;
  const bps = (raw) => ((Number(raw) - mid) / mid) * 10_000;

  const quoted = desks.filter((d) => d.quoted);
  if (!quoted.length) return;
  const desk = quoted.find((d) => d.lean !== 0) ?? worstCurve(quoted, mid) ?? quoted[0];

  // The flat curve's marginal price on this desk's own reserves, in the book's raw units. A
  // curve has one price, not a bid and an ask — that asymmetry is half the picture.
  const curveRaw = marginalCurve(desk);
  const dev = curveRaw === null ? null : bps(curveRaw);

  // Wide enough for the desk's band, its quiet band, and the curve's tick wherever it wandered,
  // so nothing moves off the axis at the moment the picture is meant to show a move.
  const reach = Math.max(
    30,
    Math.abs(bps(desk.bidPx)), Math.abs(bps(desk.askPx)),
    Math.abs(bps(book.bid)) + desk.params.quietBps, Math.abs(bps(book.ask)) + desk.params.quietBps,
    ...(dev === null ? [] : [Math.abs(dev)]),
  ) * 1.15;

  const rows = 2 + (dev === null ? 0 : 1);
  const leaning = desk.lean !== 0;
  const height = PAD.top + PAD.bottom + ROW * rows + (leaning ? 12 : 0);
  const x = (v) => PAD.left + ((v + reach) / (2 * reach)) * (W - PAD.left - PAD.right);

  const parts = [];
  // the axis: zero is the book's mid
  parts.push(`<line class="strip-zero" x1="${x(0)}" y1="${PAD.top - 8}" x2="${x(0)}" y2="${height - PAD.bottom + 4}"/>`);
  for (const tick of [-reach / 2, reach / 2]) {
    parts.push(`<line class="strip-grid" x1="${x(tick)}" y1="${PAD.top - 8}" x2="${x(tick)}" y2="${height - PAD.bottom + 4}"/>`);
  }
  for (const tick of [-reach, -reach / 2, 0, reach / 2, reach]) {
    parts.push(`<text class="strip-tick" x="${x(tick)}" y="${height - 8}" text-anchor="middle">${
      tick === 0 ? "book mid" : `${tick > 0 ? "+" : ""}${Math.round(tick)}`
    }</text>`);
  }

  // the book's own band, on the first row
  const l1 = { lo: bps(book.bid), hi: bps(book.ask) };
  parts.push(row(x, PAD.top, "the book", l1, "strip-l1"));

  // the desk's band, on the second
  const dy = PAD.top + ROW;
  const band = { lo: bps(desk.bidPx), hi: bps(desk.askPx) };
  const quiet = { lo: l1.lo - desk.params.quietBps, hi: l1.hi + desk.params.quietBps };
  // Where this desk sits when it is not leaning, so the move has something to be measured from.
  // It is a display outline, not a price: the solid band beside it is the contract's own answer.
  if (leaning) parts.push(ghost(x, dy, quiet));
  parts.push(row(x, dy, label(desk), band, "strip-desk"));

  // the wedge: where this desk is quoting inside the book, and how far it moved to get there
  if (band.lo > l1.lo) {
    parts.push(wedge(x, dy, l1.lo, band.lo, "strip-wedge-bid"));
    parts.push(edge(x, dy, band.lo, "strip-lean-bid"));
    parts.push(travel(x, dy, quiet.lo, band.lo, "strip-travel-bid"));
  }
  if (band.hi < l1.hi) {
    parts.push(wedge(x, dy, band.hi, l1.hi, "strip-wedge-ask"));
    parts.push(edge(x, dy, band.hi, "strip-lean-ask"));
    parts.push(travel(x, dy, band.hi, quiet.hi, "strip-travel-ask"));
  }

  // the flat curve, on the third: one price, and its distance from the mid as the label. The
  // tick reaches into the book's row on purpose — the toll is measured against that band, so
  // the marker points at it.
  if (dev !== null) {
    const cy = PAD.top + ROW * 2;
    parts.push(
      `<line class="strip-curve" x1="${x(dev)}" y1="${cy - 2}" x2="${x(dev)}" y2="${cy + 20}"/>` +
      `<text class="strip-name" x="${x(0)}" y="${cy - 4}" text-anchor="middle">a plain curve, same reserves</text>` +
      `<text class="strip-curve-label" x="${x(dev) + (dev < 0 ? -8 : 8)}" y="${cy + 13}" ` +
      `text-anchor="${dev < 0 ? "end" : "start"}">${fmt(dev)} bps from mid</text>`
    );
  }

  host.innerHTML =
    `<svg viewBox="0 0 ${W} ${height}" preserveAspectRatio="none" role="img" aria-label="the desk's band, a flat curve's price, and the book's own">${parts.join("")}</svg>`;
}

/** The desk whose unclamped curve sits furthest from the book — the one the toll is counted on. */
function worstCurve(desks, mid) {
  let worst = null;
  let worstDev = 0;
  for (const d of desks) {
    const raw = marginalCurve(d);
    if (raw === null) continue;
    const dev = Math.abs((raw - mid) / mid);
    if (dev > worstDev) { worstDev = dev; worst = d; }
  }
  return worst;
}

/** The constant-product ratio of the desk's own reserves, in the book's raw units. Null on dust. */
function marginalCurve(desk) {
  const B = Number(desk.baseBalance) / 1e8;
  const Q = Number(desk.quoteBalance) / 1e6;
  if (!(B > 0 && Q > 0)) return null;
  return (Q / B) * 10;
}

function row(x, y, name, band, cls) {
  const left = x(band.lo);
  const width = Math.max(2, x(band.hi) - left);
  return (
    `<rect class="${cls}" x="${left}" y="${y}" width="${width}" height="18" rx="2"/>` +
    `<text class="strip-name" x="${x(0)}" y="${y - 4}" text-anchor="middle">${escape(name)}</text>` +
    `<text class="strip-edge" x="${left - 6}" y="${y + 13}" text-anchor="end">${fmt(band.lo)}</text>` +
    `<text class="strip-edge" x="${left + width + 6}" y="${y + 13}">${fmt(band.hi)}</text>`
  );
}

const wedge = (x, y, lo, hi, cls) =>
  `<rect class="${cls}" x="${x(lo)}" y="${y}" width="${Math.max(1, x(hi) - x(lo))}" height="18"/>`;

/** The leaning side of the band, drawn heavy: the wedge can be sub-pixel, this cannot. */
const edge = (x, y, at, cls) =>
  `<line class="${cls}" x1="${x(at)}" y1="${y - 2}" x2="${x(at)}" y2="${y + 20}"/>`;

const ghost = (x, y, band) =>
  `<rect class="strip-ghost" x="${x(band.lo)}" y="${y}" width="${Math.max(2, x(band.hi) - x(band.lo))}" height="18" rx="2"/>`;

/** How far this side travelled to get inside, with the number on it. */
function travel(x, y, from, to, cls) {
  const [a, b] = [x(from), x(to)];
  const span = Math.abs(to - from);
  return (
    `<line class="${cls}" x1="${a}" y1="${y + 9}" x2="${b}" y2="${y + 9}"/>` +
    `<text class="strip-travel-label" x="${(a + b) / 2}" y="${y + 30}" text-anchor="middle">` +
    `moved ${span.toFixed(1)} bps</text>`
  );
}

const fmt = (v) => `${v > 0 ? "+" : ""}${v.toFixed(1)}`;
const label = (d) => (d.label && d.label.length ? d.label : "canonical");
const escape = (s) => s.replace(/[<>&]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;" })[c]);
