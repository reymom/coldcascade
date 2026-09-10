// Loads results/oct10_replay.csv. The column list is the frozen schema: the same 45 names are
// pinned in test/Oct10Replay.t.sol's HEADER, in results/oct10_replay.schema.md and in types.ts.
// If a column moves, this throws here rather than drawing a wrong picture quietly.
//
// Four lines, not two. The desk, the plain XYCSwap control it is an ablation of, the same curve
// charging a maker fee — which is what people actually deploy — and Hyperliquid's own touch, which
// is not a maker at all and is there so that "compared to what?" has an answer nobody can call a
// strawman.

export const REPLAY_COLUMNS = [
  "t", "spot", "bid", "ask", "mark", "oracle", "deskBid", "deskAsk", "lean", "dislocationBps",
  "mapBelowNtl", "mapAboveNtl", "forcedSellNtl", "forcedBuyNtl", "baseDesk", "quoteDesk",
  "baseControl", "quoteControl", "pnlDeskBps", "pnlControlBps", "absorbedDeskNtl",
  "absorbedControlNtl", "arbDeskNtl", "arbControlNtl", "markoutDesk5mBps", "markoutDesk15mBps",
  "markoutDesk60mBps", "markoutControl5mBps", "markoutControl15mBps", "markoutControl60mBps",
  "baseHard", "quoteHard", "pnlHardBps", "absorbedHardNtl", "arbHardNtl",
  "markoutHard5mBps", "markoutHard15mBps", "markoutHard60mBps",
  "absorbedTouchNtl", "markoutTouch5mBps", "markoutTouch15mBps", "markoutTouch60mBps",
  "lvrDeskNtl", "lvrControlNtl", "lvrHardNtl",
  // the oracle-pegged control, added when a realistic competitor joined the pot
  "basePegged",
  "quotePegged",
  "pnlPeggedBps",
  "absorbedPeggedNtl",
  "arbPeggedNtl",
  "markoutPegged5mBps",
  "markoutPegged15mBps",
  "markoutPegged60mBps",
  "lvrPeggedNtl",
];

export const LEAN = ["none", "bid", "ask"];

// Raw HyperCore units per USD for szDecimals 5, which is BTC.
export const RAW_PER_USD = 10;

export class SchemaDrift extends Error {}

export function parseReplay(text) {
  const lines = text.trim().split("\n");
  const header = lines[0].split(",");

  if (header.length !== REPLAY_COLUMNS.length || header.some((c, i) => c !== REPLAY_COLUMNS[i])) {
    throw new SchemaDrift(
      `the CSV header is not the frozen schema.\n  expected: ${REPLAY_COLUMNS.join(",")}\n  got:      ${header.join(",")}`
    );
  }

  return lines.slice(1).map((line) => {
    const cells = line.split(",");
    const row = {};
    REPLAY_COLUMNS.forEach((name, i) => { row[name] = Number(cells[i]); });
    row.leanName = LEAN[row.lean] ?? "none";
    row.mid = (row.bid + row.ask) / 2;
    return row;
  });
}

export async function loadReplay(url) {
  const resp = await fetch(url, { cache: "no-store" });
  if (!resp.ok) throw new Error(`${url}: ${resp.status} ${resp.statusText}`);
  return parseReplay(await resp.text());
}

// Distance from the L1 mid, in bps. The only scale on which a 25 bps quote and a $7 000 crash fit
// in the same picture.
export const bpsFromMid = (px, mid) => ((px - mid) / mid) * 10_000;

export const usd = (raw) => raw / RAW_PER_USD;

export const hhmm = (unixSeconds) =>
  new Date(unixSeconds * 1000).toISOString().slice(11, 16);
