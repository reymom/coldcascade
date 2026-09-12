// The book archive: what Hyperliquid's BBO *was* at a past instant — the query no RPC can
// answer, because the HyperCore precompiles ignore the block tag and return the present without
// erroring. That instant exists only because BookCache.poke wrote it into a log while it was
// true.
//
// This panel is the browser twin of the MCP server in mcp/: it reads the same series as a static
// file (results/book-archive.json, written by the same keeper pass as the record), builds the
// same response object, and keeps the same discipline. A moment between two pokes returns the
// two observations that bracket it, each with its distance in seconds — never a number, because
// a midpoint would look like data and be a guess. A moment before the first poke returns the
// absence by its name, beforeSeries: never observed, and unrecoverable from anywhere. The
// refusal is the thing to teach, not to hide.
//
// Under every answer, the call: the Substreams command that regenerates the observation from the
// stream, and the cast command that checks it against the chain. A judge has to be able to
// repeat what they see — that is half the value.

const FILE = "../results/book-archive.json";
const POLL_MS = 60_000;

// What the file does not carry: the event's topic, and the package's path inside the repository.
// The endpoint, package name and module come from the file's own `source` when present.
const TOPIC_BOOKED = "0xd4d04ff23def09886e62b85b81ad08f3c4968122f84db18b16faaf72fc4cf305";
const ENDPOINT = "hyperevm.substreams.pinax.network:443";
const SPKG = "substreams/coldcascade-v0.1.0.spkg";
const MODULE = "desk_events";

const HOLE_SECONDS = 180;   // what the archive calls "wider than the one-minute cadence"
const BTC_RAW_PER_USD = 10; // raw = USD * 10^(6 - szDecimals); BTC szDecimals is 5

// The two limits the MCP server attaches to every answer, verbatim — the fold below shows the
// response object next to the server's, so the words are the server's.
const LIMITS = {
  notForTrading:
    "Observations and their limits. This server does not produce trading advice, signals or recommendations.",
  priceScale:
    "Raw L1 units, USD * 10^(6 - szDecimals). BTC: divide by 10. *Usd fields are converted.",
};

// Unix seconds from a unix number or an ISO-8601 string. UTC unless an offset is given — the
// same reading the server's parse_time gives, so both answer the same string the same way.
export function parseTime(raw) {
  const s = String(raw).trim();
  if (!s) throw new Error("empty");
  if (/^\d+(\.\d+)?$/.test(s)) return Math.floor(Number(s));
  let text = s.replace(" ", "T");
  if (!/[zZ]$/.test(text) && !/[+-]\d{2}:?\d{2}$/.test(text)) text += "Z";
  const ms = Date.parse(text);
  if (!Number.isFinite(ms)) throw new Error("unparseable");
  return Math.floor(ms / 1000);
}

const iso = (t) => new Date(t * 1000).toISOString().slice(0, 19) + "Z";

// One observation, in the server's field names: every price twice, raw and converted.
const obsOut = (o) => ({
  atBlock: o.block,
  atTime: iso(o.t),
  atUnix: o.t,
  bidRaw: o.bid, askRaw: o.ask,
  markRaw: o.mark, oracleRaw: o.oracle,
  bidUsd: o.bid / BTC_RAW_PER_USD,
  askUsd: o.ask / BTC_RAW_PER_USD,
  markUsd: o.mark / BTC_RAW_PER_USD,
  oracleUsd: o.oracle / BTC_RAW_PER_USD,
  midUsd: (o.bid + o.ask) / 2 / BTC_RAW_PER_USD,
  spreadRaw: o.ask - o.bid,
});

// The same answer get_book_at_time gives, built the same way: the last observation at or before
// the moment, the first at or after it, and the distance of each. Never a fitted value.
export function bookAt(doc, t) {
  const obs = doc.observations ?? [];
  const query = { time: iso(t), unix: t };
  if (!obs.length) return { query, status: "noData", reason: "the corpus holds no Booked events" };

  let lo = 0, hi = obs.length;
  while (lo < hi) { const mid = (lo + hi) >> 1; if (obs[mid].t < t) lo = mid + 1; else hi = mid; }
  const idx = lo;
  const exact = idx < obs.length && obs[idx].t === t;
  const before = exact ? obs[idx] : idx > 0 ? obs[idx - 1] : null;
  const after = exact ? null : idx < obs.length ? obs[idx] : null;
  const first = obs[0], last = obs[obs.length - 1];

  if (!before) {
    const body = {
      query, status: "beforeSeries", before: null, after: obsOut(first),
      seriesStart: { atBlock: first.block, atTime: iso(first.t) },
      explanation:
        "The requested moment predates the first poke. Before it there was no `Booked` event " +
        "on chain 999 at all, so this instant was never observed and cannot be recovered from " +
        "anywhere — the precompiles keep no history.",
    };
    body.provenance = provenance(doc, first.block);
    body.limits = { ...(doc.limits ?? {}), ...LIMITS };
    return body;
  }

  const [status, note] = exact
    ? ["exact", "A poke landed at the requested moment."]
    : !after
      ? ["stale",
         "The series has not reached the requested moment yet; what is returned is the most " +
         "recent observation before it."]
      : ["bracketed",
         "No poke landed at the requested moment. Both neighbours are returned; nothing between " +
         "them was observed and no value has been interpolated."];

  const body = {
    query, status,
    before: obsOut(before),
    after: after ? obsOut(after) : null,
    interpolated: false,
    explanation: note,
  };
  body.before.ageSeconds = t - before.t;
  if (after) body.after.aheadSeconds = after.t - t;
  const gap = after ? after.t - before.t : 0;
  if (gap) {
    body.observationGapSeconds = gap;
    if (gap > HOLE_SECONDS) {
      body.warning =
        `The two observations are ${gap}s apart, wider than the one-minute cadence. BTC can move ` +
        "materially inside that; treat the bracket as the bound, not as a small uncertainty.";
    }
  }
  body.seriesCoverage = {
    firstAtTime: iso(first.t), firstAtBlock: first.block,
    lastAtTime: iso(last.t), lastAtBlock: last.block,
    observations: obs.length,
  };
  body.provenance = provenance(doc, before.block);
  body.limits = { ...(doc.limits ?? {}), ...LIMITS };
  return body;
}

// How to obtain the same answer without this page. Attached to every answer, as the server does.
function provenance(doc, blk) {
  const src = doc.source ?? {};
  const endpoint = src.endpoint ?? ENDPOINT;
  const pkg = src.package ? `substreams/${src.package}` : SPKG;
  const mod = src.module ?? MODULE;
  const p = {
    chainId: doc.chainId ?? 999,
    provider: src.provider ?? "The Graph Market for Substreams",
    endpoint, package: pkg, module: mod,
    contract: doc.contract,
    event: doc.event,
    topic0: TOPIC_BOOKED,
  };
  if (blk) {
    // Continuation backslashes, like The Keys' "check it yourself": the command wraps where a
    // shell would, not mid-token where the column ends.
    p.reproduce =
      `substreams run -e ${endpoint} \\\n  ${pkg} ${mod} -s ${blk} -t +1 -o json`;
    p.verifyAgainstTheChain =
      `cast logs --from-block ${blk} --to-block ${blk} \\\n  --address ${doc.contract} \\\n  ${TOPIC_BOOKED} \\\n  --rpc-url $HYPEREVM_RPC_URL`;
  }
  // The server's constant points at markouts.json; the artifact this panel serves is this one.
  p.artifact = "https://coldcascade.vercel.app/results/book-archive.json";
  return p;
}

// ---- the panel -----------------------------------------------------------------------------

export async function mountArchive(root) {
  const ui = {
    input: root.querySelector("#archive-when"),
    go: root.querySelector("#archive-go"),
    presets: root.querySelector("#archive-presets"),
    status: root.querySelector("#archive-status"),
    answer: root.querySelector("#archive-answer"),
    chip: root.querySelector("#archive-chip"),
    explanation: root.querySelector("#archive-explanation"),
    bracket: root.querySelector("#archive-bracket"),
    refusal: root.querySelector("#archive-refusal"),
    gapline: root.querySelector("#archive-gap"),
    nointerp: root.querySelector("#archive-nointerp"),
    warn: root.querySelector("#archive-warn"),
    reproduce: root.querySelector("#archive-reproduce"),
    verify: root.querySelector("#archive-verify"),
    json: root.querySelector("#archive-json"),
    meta: root.querySelector("#archive-meta"),
    start: root.querySelector("#archive-start"),
  };
  if (!ui.input) return;

  let doc = null;

  const ask = (raw) => {
    let t;
    try {
      t = parseTime(raw);
    } catch {
      ui.status.textContent =
        `could not read "${raw}" as a time — ISO-8601 like 2026-09-08T16:30:00Z, or unix ` +
        "seconds. No offset means UTC.";
      return;
    }
    if (!doc) {
      ui.status.textContent = "the archive has not loaded yet — one moment.";
      return;
    }
    ui.status.textContent = "";
    render(ui, doc, bookAt(doc, t));
  };

  ui.go.addEventListener("click", () => ask(ui.input.value));
  ui.input.addEventListener("keydown", (e) => { if (e.key === "Enter") ask(ui.input.value); });
  ui.presets.addEventListener("click", (e) => {
    const b = e.target.closest("[data-when]");
    if (!b) return;
    ui.input.value = b.dataset.when;
    ask(b.dataset.when);
  });
  // The archive hangs from the fills: every row of the record and the scatter's hover readout
  // carry their own instant in data-archive-at, and clicking one asks this panel that instant.
  // Delegated on the root, because the record re-renders its rows on every poll.
  root.addEventListener("click", (e) => {
    const b = e.target.closest("[data-archive-at]");
    if (!b) return;
    const t = Number(b.dataset.archiveAt);
    if (!Number.isFinite(t)) return;
    ui.input.value = iso(t);
    ask(ui.input.value);
    root.querySelector("#archive")?.scrollIntoView({ behavior: "smooth", block: "start" });
  });
  for (const b of root.querySelectorAll("[data-copy]")) {
    b.addEventListener("click", () => copyCommand(b, root));
  }

  const tick = async () => {
    try {
      const res = await fetch(FILE, { cache: "no-store" });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      doc = await res.json();
      renderFoot(ui, doc);
      // The standing question is answered again against the fresher file: the newest observation
      // moves, and a "stale" answer can become a bracketed one.
      if (ui.input.value.trim()) ask(ui.input.value);
    } catch (err) {
      // As the record does: a failed read keeps the last good render and says so, and on first
      // load the status line is the whole section.
      if (!doc) {
        ui.status.textContent =
          `the archive could not be read — ${FILE}: ${err.message}. ` +
          "The keeper writes it on the same pass as the record, every twenty minutes.";
      }
    }
  };
  await tick();
  setInterval(tick, POLL_MS);

  // The panel never waits empty: the first preset is the instant the SKILL manual works through,
  // so the page and the MCP server answer the same moment with the same numbers.
  const firstPreset = ui.presets.querySelector("[data-when]");
  if (firstPreset && doc) {
    ui.input.value = firstPreset.dataset.when;
    ask(firstPreset.dataset.when);
  }
}

function render(ui, doc, body) {
  if (body.status === "noData") {
    ui.answer.hidden = true;
    ui.status.textContent = body.reason;
    return;
  }
  ui.answer.hidden = false;
  ui.chip.textContent = body.status;
  ui.chip.className = `chip ba-chip-${body.status.toLowerCase()}`;
  ui.explanation.innerHTML = codeify(body.explanation);

  const beforeSeries = body.status === "beforeSeries";
  ui.bracket.hidden = beforeSeries;
  ui.refusal.hidden = !beforeSeries;

  if (beforeSeries) {
    // The refusal is the exhibit. No book is returned for the asked instant, and the reason an
    // RPC cannot bail the question out is stated in full, because that is the claim. The bracket
    // cards are cleared, not just hidden — a grid rule can override [hidden] and leave a stale
    // card visible next to the refusal.
    ui.bracket.innerHTML = "";
    ui.refusal.innerHTML =
      `<h3>never observed — and unrecoverable from anywhere</h3>` +
      `<p>The chain answers this anyway, with the present: the precompiles ignore the block tag, ` +
      `so asking for the past returns the current book without an error. No archive node does ` +
      `better — the book was node state, never chain state. Nobody wrote this moment down while ` +
      `it was true.</p>` +
      `<p>The series starts <b>${body.seriesStart.atTime}</b>, block ` +
      `<b>${num(body.seriesStart.atBlock)}</b>. Run the call below over any earlier range and it ` +
      `comes back empty.</p>`;
    ui.gapline.textContent = "";
    ui.nointerp.textContent = "";
    ui.warn.hidden = true;
  } else {
    const cards = [];
    if (body.status === "exact") {
      cards.push(card("a poke landed at that exact second", body.before, null));
    } else {
      if (body.before) {
        cards.push(card("last observation at or before", body.before,
          `${num(body.before.ageSeconds)} s before the moment asked`));
      }
      if (body.after) {
        cards.push(card("first observation at or after", body.after,
          `${num(body.after.aheadSeconds)} s after the moment asked`));
      }
    }
    ui.bracket.innerHTML = cards.join("");
    ui.refusal.innerHTML = "";
    ui.gapline.textContent = body.observationGapSeconds
      ? `the two observations are ${num(body.observationGapSeconds)} s apart — ` +
        (body.observationGapSeconds > 60 ? "over" : "inside") + " the 60 s cadence"
      : "";
    ui.nointerp.innerHTML = body.status === "bracketed"
      ? `<code>interpolated: false</code> — nothing between the two observations was observed.`
      : body.status === "stale"
        ? `<code>interpolated: false</code> — the series in this file has not reached that ` +
          `moment yet; what you see is its newest observation, not a guess at the present.`
        : `<code>interpolated: false</code> — and nothing to bound: the poke is the exact ` +
          `second asked for.`;
    if (body.warning) {
      ui.warn.textContent = body.warning;
      ui.warn.hidden = false;
    } else {
      ui.warn.hidden = true;
    }
  }

  ui.reproduce.textContent = body.provenance.reproduce ?? "—";
  ui.verify.textContent = body.provenance.verifyAgainstTheChain ?? "—";
  ui.json.textContent = JSON.stringify(body, null, 2);
}

const card = (k, o, dist) =>
  `<div class="ba-card">` +
  `<div class="ba-card-k">${k}</div>` +
  `<div class="ba-card-when">${o.atTime} · block ${num(o.atBlock)}</div>` +
  `<div class="ba-card-book"><span class="b">${usd(o.bidRaw)}</span> / ` +
  `<span class="a">${usd(o.askRaw)}</span></div>` +
  `<div class="ba-card-s">mark ${usd(o.markRaw)} · oracle ${usd(o.oracleRaw)} · ` +
  `spread ${o.spreadRaw} raw</div>` +
  `<div class="ba-card-s">as logged: bid ${o.bidRaw} · ask ${o.askRaw} — raw L1 units; BTC, ` +
  `divide by ten</div>` +
  (dist ? `<div class="ba-dist">${dist}</div>` : "") +
  `</div>`;

function renderFoot(ui, doc) {
  const obs = doc.observations ?? [];
  if (!obs.length) return;
  const first = obs[0], last = obs[obs.length - 1];
  let holes = 0;
  for (let i = 1; i < obs.length; i++) if (obs[i].t - obs[i - 1].t > HOLE_SECONDS) holes++;
  const now = Math.floor(Date.now() / 1000);
  const age = Math.max(0, now - (doc.generatedAt ?? now));
  const src = doc.source ?? {};
  if (ui.start) {
    ui.start.textContent =
      ` The series starts ${iso(first.t)}, block ${num(first.block)}; before it there is ` +
      `nothing, and the panel says so.`;
  }
  // What the old foot carried, rebuilt as short lines under the answer — not a duplication of the
  // cards above: the corpus' own size, its holes, and what the file cannot answer for a moment.
  ui.meta.innerHTML =
    `<div><b>${num(obs.length)} observations</b> · ${iso(first.t)} → ${iso(last.t)} · ` +
    `blocks ${num(first.block)}–${num(last.block)}</div>` +
    `<div>60 s cadence · <b>${holes}</b> hole${holes === 1 ? "" : "s"} over 180 s · streamed by ` +
    `Substreams on ${escapeHtml(src.provider ?? "The Graph Market for Substreams")} · module ` +
    `${escapeHtml(src.module ?? MODULE)}</div>` +
    `<div>Last published <b>${ageText(age)}</b> · the file cannot answer before the first poke, ` +
    `between two observations, or depth beyond the touch — four uint64 are a touch, not a book.</div>`;
}

async function copyCommand(btn, root) {
  const el = root.querySelector(`#${btn.dataset.copy}`);
  const text = el?.textContent ?? "";
  try {
    await navigator.clipboard.writeText(text);
    btn.textContent = "copied";
  } catch {
    // No clipboard permission: select the command instead, so a manual copy is one keystroke.
    const range = document.createRange();
    range.selectNodeContents(el);
    const sel = getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    btn.textContent = "selected — ctrl+c";
  }
  setTimeout(() => { btn.textContent = "copy"; }, 1600);
}

const usd = (raw) =>
  `$${(raw / BTC_RAW_PER_USD).toLocaleString("en-US", { minimumFractionDigits: 1, maximumFractionDigits: 1 })}`;
const num = (v) => (Number.isFinite(v) ? v.toLocaleString("en-US") : "—");
const ageText = (s) =>
  s < 60 ? "just now"
  : s < 3600 ? `${Math.floor(s / 60)} min ago`
  : `${Math.floor(s / 3600)} h ${Math.round((s % 3600) / 60)} min ago`;
const escapeHtml = (s) =>
  String(s).replace(/[<>&]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;" })[c]);
const codeify = (s) => escapeHtml(s).replace(/`([^`]+)`/g, "<code>$1</code>");
