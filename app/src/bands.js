// The two books, live. The same picture as the Oct-10 tab's centre panel, on one instant instead of
// a session: L1's spread as a grey band, each desk's as its own, both in basis points from L1's
// mid — the only scale on which a 20 bps quote and an $80 000 price fit on one axis.
//
// The wedge is the point. When a desk's band crosses inside L1's, the overlap is filled: amber on
// the bid, where the desk is buying from forced sellers, teal on the ask. In the quiet there is no
// wedge, and that is the honest picture of a desk that cannot be taken stale.
//
// The wedge is often *small*, and the reason is worth reading off the picture rather than
// explaining away. A leaning quote is capped at L1's own price on that side — the desk never beats
// what crossing L1 would pay — so the wedge can never be wider than L1's spread, and on a quiet
// book that is a tenth of a basis point. What is large is the **move**: the desk's bid goes from 20
// bps outside to the cap, twenty basis points in one tick. So the row carries both, and the ghost
// outline is where that desk sits when it is not leaning, drawn from its own quietBps so the
// distance it travelled is on the screen and not in a sentence underneath it.

const W = 1000;
const ROW = 32;
const PAD = { top: 18, bottom: 26, left: 8, right: 8 };

export function drawStrip(host, book, desks) {
  const mid = (Number(book.bid) + Number(book.ask)) / 2;
  if (!Number.isFinite(mid) || mid === 0) return;
  const bps = (raw) => ((Number(raw) - mid) / mid) * 10_000;

  const drawn = desks.filter((d) => d.quoted);
  // Wide enough for every band *and* for the quiet band each leaning desk left behind, so nothing
  // moves off the axis at the moment the picture is meant to show a move.
  const reach = Math.max(
    30,
    ...drawn.flatMap((d) => [
      Math.abs(bps(d.bidPx)), Math.abs(bps(d.askPx)),
      Math.abs(bps(book.bid)) + d.params.quietBps, Math.abs(bps(book.ask)) + d.params.quietBps,
    ]),
  ) * 1.15;

  const leaning = drawn.some((d) => d.lean !== 0);
  const height = PAD.top + PAD.bottom + ROW * (drawn.length + 1) + (leaning ? 12 : 0);
  const x = (v) => PAD.left + ((v + reach) / (2 * reach)) * (W - PAD.left - PAD.right);

  const parts = [];
  // the axis: zero is L1's mid
  parts.push(`<line class="strip-zero" x1="${x(0)}" y1="${PAD.top - 8}" x2="${x(0)}" y2="${height - PAD.bottom + 4}"/>`);
  for (const tick of [-reach / 2, reach / 2]) {
    parts.push(`<line class="strip-grid" x1="${x(tick)}" y1="${PAD.top - 8}" x2="${x(tick)}" y2="${height - PAD.bottom + 4}"/>`);
  }
  for (const tick of [-reach, -reach / 2, 0, reach / 2, reach]) {
    parts.push(`<text class="strip-tick" x="${x(tick)}" y="${height - 8}" text-anchor="middle">${
      tick === 0 ? "L1 mid" : `${tick > 0 ? "+" : ""}${Math.round(tick)}`
    }</text>`);
  }

  // L1's own band, on the first row
  const l1 = { lo: bps(book.bid), hi: bps(book.ask) };
  parts.push(row(x, PAD.top, "L1", l1, "strip-l1"));

  drawn.forEach((desk, i) => {
    const y = PAD.top + ROW * (i + 1);
    const band = { lo: bps(desk.bidPx), hi: bps(desk.askPx) };
    const quiet = { lo: l1.lo - desk.params.quietBps, hi: l1.hi + desk.params.quietBps };

    // Where this desk sits when it is not leaning, so the move has something to be measured from.
    // It is a display outline, not a price: the solid band beside it is the contract's own answer.
    if (desk.lean !== 0) parts.push(ghost(x, y, quiet));
    parts.push(row(x, y, label(desk), band, "strip-desk"));

    // the wedge: where this desk is quoting inside L1, and how far it moved to get there
    if (band.lo > l1.lo) {
      parts.push(wedge(x, y, l1.lo, band.lo, "strip-wedge-bid"));
      parts.push(edge(x, y, band.lo, "strip-lean-bid"));
      parts.push(travel(x, y, quiet.lo, band.lo, "strip-travel-bid"));
    }
    if (band.hi < l1.hi) {
      parts.push(wedge(x, y, band.hi, l1.hi, "strip-wedge-ask"));
      parts.push(edge(x, y, band.hi, "strip-lean-ask"));
      parts.push(travel(x, y, band.hi, quiet.hi, "strip-travel-ask"));
    }
  });

  host.innerHTML =
    `<svg viewBox="0 0 ${W} ${height}" preserveAspectRatio="none" role="img" aria-label="the two books">${parts.join("")}</svg>`;
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
