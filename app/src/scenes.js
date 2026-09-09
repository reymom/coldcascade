// The mechanism in five scenes, navigable, in-page — not a rendered video: it screen-records
// just as well and the frontend builds it.
//
// One constant axis across all five scenes, the same one the Desk's live strip uses: distance
// to the book's mid, in basis points. The grey band is the book's own touch and it never moves
// inside a scene — when the book breaks, the scene changes and the band's new position is the
// event. The desk's band sits outside it in the quiet; in scene 4 one boolean flips, the bound
// stops being a cap and becomes a floor, and the desk's bid crosses INSIDE the band — the best
// bid in the market. That crossing is what the five scenes exist to make unambiguous, and it is
// why scenes 2, 4 and 5 keep the quiet ↔ absorbing switch live for the reader: seeing it happen
// is good, being able to make it happen is better.
//
// The five: (1) an ordinary AMM — price from reserves, market moves, a bot pockets the gap:
// that is LVR. (2) This desk — same move, quote computed during the trade from the book it just
// read: nothing to carry. (3) The book breaks — forced sellers, and the AMM is emptied at the
// old ratio. (4) The boolean flips and the desk steps into the band, buying what the forced
// sellers must sell, capped by the book's own price. (5) The recovery — the desk is long from
// the bottom.
//
// Geometry is chosen, not measured: these are teaching drawings of a rule the rest of the page
// measures live. The numbers on the axis are basis points and the axis is fixed at ±62, so a
// band that moves between scenes moves on the same ruler. Cuts are discrete — no tween — so any
// frame of a screen capture is a correct, legible frame.

const W = 1000;
const ROW = 34;
const PAD = { top: 26, bottom: 30, left: 10, right: 10 };
const DOMAIN = 62; // fixed ±bps: the ruler never stretches between scenes

const SCENES = [
  {
    title: "an ordinary AMM",
    caption:
      "Its price comes from its reserves. The market moved; the reserves did not. A bot buys " +
      "from the curve below the book's bid and sells into it — the difference it pockets is " +
      "LVR, and every cent of it was the curve's to keep.",
    book: { lo: -2, hi: 2 },
    desk: null,
    curve: { at: -14 },
    bot: { cls: "loss", msg: "the bot takes the difference — the curve pays it, every block" },
  },
  {
    title: "this desk",
    caption:
      "Same move. The desk's quote is computed during the trade, from the book it just read, " +
      "sitting its own quietBps outside the band. The same bot search, both directions, closing " +
      "at the book's own touch, finds nothing to carry.",
    book: { lo: -2, hi: 2 },
    desk: {
      quiet: { lo: -22, hi: 22 },
      absorbing: { lo: -0.8, hi: 22 },
      startsAbsorbing: false,
      outside: "$0.00 — nothing to carry",
      inside: "inside the book — the best bid in the market",
    },
    curve: null,
    bot: { cls: "gain" },
  },
  {
    title: "the book breaks",
    caption:
      "Forced sellers hit the bid and the book slides. The ordinary AMM still quotes the old " +
      "ratio — its reserves cannot know what happened — so it is emptied at it, again.",
    book: { lo: -38, hi: -34 },
    desk: null,
    curve: { at: -9 },
    bot: { cls: "loss", msg: "emptied at the old ratio, at the size of whoever comes first" },
  },
  {
    title: "the boolean flips",
    caption:
      "One boolean flips: the bound that capped the quote becomes a floor under it. The desk " +
      "steps inside the band — the best bid in the market — and buys what the forced sellers " +
      "have to sell, capped by the book's own price. Flip it back yourself; the switch is live.",
    book: { lo: -38, hi: -34 },
    desk: {
      quiet: { lo: -58, hi: -13 },
      absorbing: { lo: -37.2, hi: -13 },
      startsAbsorbing: true,
      outside: "still outside both sides — the bound is still a cap",
      inside: "the best bid in the market — buying what the sellers must sell",
    },
    curve: null,
    bot: { cls: "gain" },
  },
  {
    title: "the recovery",
    caption:
      "The book comes back. The desk was filled inside the band at the bottom, so it is long " +
      "from there — the same property that paid nothing to arbitrage in the quiet is the " +
      "property that buys the cascade.",
    book: { lo: -38, hi: -34 },
    desk: {
      quiet: { lo: -58, hi: -13 },
      absorbing: { lo: -37.2, hi: -13 },
      startsAbsorbing: true,
      outside: "the boolean is back at quiet — the desk sits outside, as before",
      inside: "long from the bottom",
    },
    curve: null,
    bot: { cls: "gain" },
  },
];

export function mountScenes(root) {
  const ui = {
    stage: root.querySelector("#scenes-stage"),
    dots: root.querySelector("#scenes-dots"),
    prev: root.querySelector("#scenes-prev"),
    next: root.querySelector("#scenes-next"),
    flip: root.querySelector("#scenes-flip"),
    caption: root.querySelector("#scenes-caption"),
  };
  if (!ui.stage) return;

  let idx = 0;
  let flipped = null; // null = the scene's own default; true/false once the reader touched it

  ui.dots.replaceChildren(
    ...SCENES.map((s, i) => {
      const b = document.createElement("button");
      b.textContent = String(i + 1);
      b.setAttribute("aria-label", s.title);
      b.addEventListener("click", () => go(i));
      return b;
    }),
  );

  const go = (i) => {
    idx = Math.max(0, Math.min(SCENES.length - 1, i));
    flipped = null; // each scene arrives as written; the reader's flip is per-scene
    render();
  };

  ui.prev.addEventListener("click", () => go(idx - 1));
  ui.next.addEventListener("click", () => go(idx + 1));
  ui.flip.addEventListener("click", () => {
    flipped = !(flipped ?? SCENES[idx].desk?.startsAbsorbing);
    render();
  });
  root.addEventListener("keydown", (e) => {
    // The arrows belong to the Cascade: while its panel is hidden they are somebody else's keys.
    if (root.querySelector("#panel-cascade")?.hidden !== false) return;
    if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === "ArrowLeft") go(idx - 1);
    if (e.key === "ArrowRight") go(idx + 1);
  });

  function render() {
    const sc = SCENES[idx];
    const absorbing = flipped ?? sc.desk?.startsAbsorbing ?? false;
    ui.stage.innerHTML = frameSvg(idx, absorbing);
    [...ui.dots.children].forEach((b, i) => b.classList.toggle("on", i === idx));
    ui.prev.disabled = idx === 0;
    ui.next.disabled = idx === SCENES.length - 1;
    ui.flip.hidden = !sc.desk;
    ui.flip.textContent = absorbing ? "absorbing — flip to quiet" : "quiet — flip to absorbing";
    ui.caption.innerHTML = `<b>${idx + 1} · ${sc.title}.</b> ${sc.caption}`;
  }

  render();
}

/** One frame of the sequence as an SVG string: the book, the desk (maybe), the AMM (maybe). */
export function frameSvg(idx, absorbing) {
  const sc = SCENES[idx];
  const height = PAD.top + ROW * 3 + PAD.bottom;
  const x = (v) => PAD.left + ((v + DOMAIN) / (2 * DOMAIN)) * (W - PAD.left - PAD.right);

  const parts = [];
  parts.push(`<line class="strip-zero" x1="${x(0)}" y1="${PAD.top - 8}" x2="${x(0)}" y2="${height - PAD.bottom + 4}"/>`);
  for (const tick of [-30, 30]) {
    parts.push(`<line class="strip-grid" x1="${x(tick)}" y1="${PAD.top - 8}" x2="${x(tick)}" y2="${height - PAD.bottom + 4}"/>`);
  }
  for (const tick of [-60, -30, 0, 30, 60]) {
    parts.push(`<text class="strip-tick" x="${x(tick)}" y="${height - 8}" text-anchor="middle">${
      tick === 0 ? "book mid" : `${tick > 0 ? "+" : ""}${tick}`
    }</text>`);
  }

  // row one: the book's own touch. The grey band is the ruler's origin — inside a scene it
  // cannot move, so anything else moving is legible against it.
  parts.push(band(x, PAD.top, "the book", sc.book, "strip-l1"));

  // row two: the desk, when the scene has one. Absorbing draws the band the flip produces, the
  // ghost outline of the quiet it came from, and — when the bid is inside the book — the wedge,
  // the heavy edge and the travel, the same three marks the live strip draws.
  if (sc.desk) {
    const dy = PAD.top + ROW;
    const shown = absorbing ? sc.desk.absorbing : sc.desk.quiet;
    const hidden = absorbing ? sc.desk.quiet : sc.desk.absorbing;
    if (absorbing) parts.push(ghost(x, dy, hidden));
    const inside = shown.lo > sc.book.lo;
    parts.push(band(x, dy, "the desk", shown, inside ? "sc-desk-in" : "strip-desk"));
    if (inside) {
      parts.push(wedge(x, dy, sc.book.lo, shown.lo, "strip-wedge-bid"));
      parts.push(edge(x, dy, shown.lo, "strip-lean-bid"));
      parts.push(travel(x, dy, hidden.lo, shown.lo, "strip-travel-bid"));
    }
  }

  // row three: the ordinary AMM, when the scene keeps it. One price, never a band — the
  // asymmetry is the whole point of putting it next to the desk.
  if (sc.curve) {
    const cy = PAD.top + ROW * 2;
    parts.push(
      `<line class="strip-curve" x1="${x(sc.curve.at)}" y1="${cy - 2}" x2="${x(sc.curve.at)}" y2="${cy + 20}"/>` +
      `<text class="strip-name" x="${x(0)}" y="${cy - 4}" text-anchor="middle">an ordinary AMM, price from its reserves</text>` +
      `<text class="strip-curve-label" x="${x(sc.curve.at) + (sc.curve.at < 0 ? -8 : 8)}" y="${cy + 13}" ` +
      `text-anchor="${sc.curve.at < 0 ? "end" : "start"}">${fmt(sc.curve.at)} bps from mid</text>`,
    );
  }

  // the consequence line: what a bot closing at the book's own touch gets out of this frame.
  // For desk scenes the reader's flip re-decides it, so the message follows the frame: a band
  // drawn inside the book is the best bid, one drawn outside is whatever the scene says quiet
  // means there. For curve scenes it is static — the frame cannot change under the reader.
  let msg = sc.bot.msg;
  if (sc.desk) {
    const shown = absorbing ? sc.desk.absorbing : sc.desk.quiet;
    msg = shown.lo > sc.book.lo ? sc.desk.inside : sc.desk.outside;
  }
  parts.push(
    `<text class="sc-bot sc-bot-${sc.bot.cls}" x="${x(0)}" y="${PAD.top + ROW * 3 + 12}" text-anchor="middle">${
      msg
    }</text>`,
  );

  const label = `${idx + 1} of ${SCENES.length}: ${sc.title}`;
  return `<svg viewBox="0 0 ${W} ${height}" role="img" aria-label="${label}">${parts.join("")}</svg>`;
}

function band(x, y, name, b, cls) {
  const left = x(b.lo);
  const width = Math.max(2, x(b.hi) - left);
  return (
    `<rect class="${cls}" x="${left}" y="${y}" width="${width}" height="18" rx="2"/>` +
    `<text class="strip-name" x="${x(0)}" y="${y - 4}" text-anchor="middle">${name}</text>` +
    `<text class="strip-edge" x="${left - 6}" y="${y + 13}" text-anchor="end">${fmt(b.lo)}</text>` +
    `<text class="strip-edge" x="${left + width + 6}" y="${y + 13}">${fmt(b.hi)}</text>`
  );
}

const ghost = (x, y, b) =>
  `<rect class="strip-ghost" x="${x(b.lo)}" y="${y}" width="${Math.max(2, x(b.hi) - x(b.lo))}" height="18" rx="2"/>`;

const wedge = (x, y, lo, hi, cls) =>
  `<rect class="${cls}" x="${x(lo)}" y="${y}" width="${Math.max(1, x(hi) - x(lo))}" height="18"/>`;

const edge = (x, y, at, cls) =>
  `<line class="${cls}" x1="${x(at)}" y1="${y - 2}" x2="${x(at)}" y2="${y + 20}"/>`;

function travel(x, y, from, to, cls) {
  const [a, b] = [x(from), x(to)];
  const span = Math.abs(to - from);
  return (
    `<line class="${cls}" x1="${a}" y1="${y + 9}" x2="${b}" y2="${y + 9}"/>` +
    `<text class="strip-travel-label" x="${(a + b) / 2}" y="${y + 33}" text-anchor="middle">` +
    `inside the book — moved ${span.toFixed(1)} bps</text>`
  );
}

const fmt = (v) => `${v > 0 ? "+" : ""}${v.toFixed(1)}`;
