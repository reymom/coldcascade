import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { T0, TAPE } from "./tape";

/**
 * The mechanism as it quoted on 10 October 2025, 21:03 → 21:37 UTC.
 *
 * Prices, spread, oracle, dislocation, liquidation map, forced flow, the desk's
 * fills and the oracle-pegged rival's losses are the minute bars of
 * `results/oct10_replay.csv`, interpolated. Illustrative, because the tape has no
 * sub-minute data and no perp leg: the breath inside a minute, the cover cadence,
 * and the timing of each spark and fill inside its minute.
 *
 * Everything is a pure function of the frame. Market time runs at ×1 in the quiet,
 * ×60 through the cascade and ×40 through the rebound; the clock shows it, and
 * every panel shares the timeline's market-time axis.
 */

export const FPS = 60;
export const DURATION = 54 * FPS;

const W = 1920;
const H = 1080;
const CX = W / 2;
const BASE = 880;
const BAR_MAX = 470;

// ─── palette ────────────────────────────────────────────────────────────────
const BG = "#07090f";
const BID = "#2f6f9e";
const ASK = "#46546e";
const EATEN = "#c0392b";
const MAP = "#a12525";
const HERO = "#f2a900";
const RIVAL = "#8e7cc3";
const ORACLE = "#e8e2d0";
const MARK = "#9ecbe8";
const INK = "#7d8ba1";
const INK2 = "#1c2433";
const SPARK = "#ff5a3c";
const WHITE = "#f4f4f0";
const TEAL = "#46d3bd";
const L1 = "#3c4c64";

const SERIF = "'Latin Modern Roman', 'LM Roman 10', Georgia, serif";
const MONO = "'Latin Modern Mono', 'LM Mono 10', 'DejaVu Sans Mono', monospace";

// ─── the canonical desk, in bps ─────────────────────────────────────────────
const QUIET = 20;
const LEAN = 15;
const STRESS = 25;
const MAP_MIN = 5_000_000;
const BAND = 40_000; // the film's inventory band, USD of base

// ─── helpers ────────────────────────────────────────────────────────────────
type KF = [number, number][];
const mono = (pts: KF) => {
  const n = pts.length;
  const xs = pts.map((p) => p[0]);
  const ys = pts.map((p) => p[1]);
  const d: number[] = [];
  const m: number[] = new Array(n).fill(0);
  for (let i = 0; i < n - 1; i++) d.push((ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]));
  m[0] = d[0];
  m[n - 1] = d[n - 2];
  for (let i = 1; i < n - 1; i++) m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2;
  for (let i = 0; i < n - 1; i++) {
    if (d[i] === 0) {
      m[i] = 0;
      m[i + 1] = 0;
      continue;
    }
    const a = m[i] / d[i];
    const b = m[i + 1] / d[i];
    const s = a * a + b * b;
    if (s > 9) {
      const tt = 3 / Math.sqrt(s);
      m[i] = tt * a * d[i];
      m[i + 1] = tt * b * d[i];
    }
  }
  return (t: number) => {
    if (t <= xs[0]) return ys[0];
    if (t >= xs[n - 1]) return ys[n - 1];
    let i = 0;
    while (xs[i + 1] < t) i++;
    const h = xs[i + 1] - xs[i];
    const u = (t - xs[i]) / h;
    const h00 = 2 * u ** 3 - 3 * u ** 2 + 1;
    const h10 = u ** 3 - 2 * u ** 2 + u;
    const h01 = -2 * u ** 3 + 3 * u ** 2;
    const h11 = u ** 3 - u ** 2;
    return h00 * ys[i] + h10 * h * m[i] + h01 * ys[i + 1] + h11 * h * m[i + 1];
  };
};
const series = (arr: number[]) => mono(arr.map((v, i) => [i * 60, v] as [number, number]));
const clamp01 = (u: number) => Math.max(0, Math.min(1, u));
const smooth = (u: number) => {
  const v = clamp01(u);
  return v * v * (3 - 2 * v);
};
const lin = (t: number, a: number, b: number) => clamp01((t - a) / (b - a));
const frac = (x: number) => x - Math.floor(x);
const gauss = (x: number) => Math.exp(-0.5 * x * x);
const erf = (x: number) => {
  const s = x < 0 ? -1 : 1;
  const a = Math.abs(x);
  const t = 1 / (1 + 0.3275911 * a);
  const y = 1 - ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.exp(-a * a);
  return s * y;
};
const Phi = (z: number) => 0.5 * (1 + erf(z / Math.SQRT2));

// ─── film time ↔ market time ────────────────────────────────────────────────
const speedAt = mono([[0, 1], [7, 1], [8.5, 60], [32.1, 60], [33.1, 40], [46.4, 40], [47.9, 1], [54, 1]]);
const TAU: number[] = [];
{
  let tau = 0;
  for (let f = 0; f < DURATION; f++) {
    TAU.push(tau);
    tau += speedAt(f / FPS) / FPS;
  }
}
const filmAt = (tau: number) => {
  let lo = 0;
  let hi = DURATION - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (TAU[mid] < tau) lo = mid + 1;
    else hi = mid;
  }
  return lo / FPS;
};
const TAPE_END = 2050; // 21:37:10 — the tape is held here while the clock settles
const AXIS_END = 35 * 60; // timeline and panels: 21:03 → 21:38
const tt = (tau: number) => Math.min(tau, TAPE_END);
const minuteOf = (tau: number) => Math.max(0, Math.min(TAPE.bid.length - 1, Math.floor(tt(tau) / 60)));

// ─── the tape, as functions of market time ──────────────────────────────────
const tBid = series(TAPE.bid);
const tAsk = series(TAPE.ask);
const tMark = series(TAPE.mark);
const tOracle = series(TAPE.oracle);
const breath = (tau: number, spread: number) => 0.03 * spread * (Math.sin(tau * 1.31) * 0.6 + Math.sin(tau * 3.7 + 1) * 0.4);
const spreadAt = (tau: number) => tAsk(tt(tau)) - tBid(tt(tau));
const markAt = (tau: number) => tMark(tt(tau)) + breath(tau, spreadAt(tau));
const oracleAt = (tau: number) => tOracle(tt(tau)) + breath(tau + 7, spreadAt(tau)) * 0.5;
const bidAt = (tau: number) => tBid(tt(tau)) + breath(tau, spreadAt(tau));
const askAt = (tau: number) => tAsk(tt(tau)) + breath(tau, spreadAt(tau));
const dislAt = (tau: number) => ((oracleAt(tau) - markAt(tau)) / oracleAt(tau)) * 1e4;
const depthAt = (tau: number) => 1 - 0.55 * smooth(lin(spreadAt(tau), 110, 520));
const mapStep = (tau: number) => TAPE.mapBelow[minuteOf(tau)];
const forcedSellAt = (tau: number) => TAPE.forcedSell[minuteOf(tau)] > 0;
const forcedBuyAt = (tau: number) => TAPE.forcedBuy[minuteOf(tau)] > 0;

/** The regime, from the same two conditions the contract reads. */
const leanAt = (tau: number): 0 | 1 | 2 => {
  const d = dislAt(tau);
  if (d >= STRESS || mapStep(tau) >= MAP_MIN) return 1;
  if (d <= -STRESS) return 2;
  return 0;
};
const deskBidAt = (tau: number, lb: number) => bidAt(tau) * ((1 - QUIET / 1e4) * (1 - lb) + (1 + LEAN / 1e4) * lb);
const deskAskAt = (tau: number, la: number) => askAt(tau) * ((1 + QUIET / 1e4) * (1 - la) + (1 - LEAN / 1e4) * la);

// ─── events, in market time ─────────────────────────────────────────────────
const COVER_EVERY = 300;
const FIRST_FILL = TAPE.absorbedDesk.findIndex((v) => v > 0) * 60 + 30; // the tape's first fill
const DESK_CHECKS = [4.6, 870, 1830]; // the arbitrageur looks at the desk and finds nothing
const RIVAL_CHECKS = [5.8]; // and at the rival, in the quiet, and finds nothing either
const HIT_DUR = 0.42; // film seconds

/** What the arbitrageur took from the oracle-pegged rival: the tape's own column, per minute. */
const takenAt = (tau: number) => {
  let s = 0;
  for (let m = 0; m < TAPE.lvrPegged.length; m++) if (tau >= m * 60 + 20) s += TAPE.lvrPegged[m];
  return s;
};
/** The same dollars as sparks on stage, thinned to one every 1.6 film-seconds, each carrying what accrued. */
const RIVAL_HITS: [number, number][] = [];
{
  let acc = 0;
  let lastFilm = -9;
  for (let m = 0; m < TAPE.lvrPegged.length; m++) {
    const usd = TAPE.lvrPegged[m];
    if (!usd) continue;
    acc += usd;
    const tau = m * 60 + 20;
    const ft = filmAt(tau);
    if (ft - lastFilm < 1.6) continue;
    RIVAL_HITS.push([tau, acc]);
    acc = 0;
    lastFilm = ft;
  }
}
const RIVAL_TOTAL = takenAt(AXIS_END);

const spotAt = (tau: number) => {
  let s = 0;
  for (let m = 0; m < TAPE.absorbedDesk.length; m++) {
    const a = TAPE.absorbedDesk[m];
    if (!a) continue;
    const sign = TAPE.lean[m] === 2 ? -1 : 1;
    s += ((sign * a) / BAND) * smooth(lin(tau, m * 60 + 10, m * 60 + 40));
  }
  return s;
};
const COVERS: number[] = [];
{
  let perp = 0;
  for (let k = 1; k * COVER_EVERY + FIRST_FILL < TAPE_END; k++) {
    const tau = FIRST_FILL + k * COVER_EVERY;
    const target = -spotAt(tau);
    if (Math.abs(target - perp) > 0.01) {
      COVERS.push(tau);
      perp = target;
    }
  }
}
const COVER_DELAY = 0.35;
const perpAt = (t: number) => {
  let v = 0;
  for (const c of COVERS) {
    const ft = filmAt(c);
    v += (-spotAt(c) - v) * smooth(lin(t, ft + COVER_DELAY, ft + COVER_DELAY + 0.6));
  }
  return v;
};
const absorbedAt = (tau: number) => {
  let s = 0;
  for (let m = 0; m < TAPE.absorbedDesk.length; m++) s += TAPE.absorbedDesk[m] * smooth(lin(tau, m * 60 + 10, m * 60 + 40));
  return s;
};
const perpAtTau = (tau: number) => {
  let v = 0;
  for (const c of COVERS) if (tau >= c) v = -spotAt(c);
  return v;
};

// ─── per-frame tables ───────────────────────────────────────────────────────
const CAM: number[] = [];
const P0: number[] = [];
const LB: number[] = [];
const LA: number[] = [];
const MAPAMP: number[] = [];
{
  let cam = markAt(0);
  let p0 = markAt(0);
  let lb = 0;
  let la = 0;
  let amp = 0;
  for (let f = 0; f < DURATION; f++) {
    const tau = TAU[f];
    const t = f / FPS;
    const m = markAt(tau) + (speedAt(t) > 5 ? 0.35 * (oracleAt(tau) - markAt(tau)) : 0); // keep the oracle side in frame
    CAM.push(cam);
    P0.push(p0);
    LB.push(lb);
    LA.push(la);
    MAPAMP.push(amp);
    const fast = speedAt(t) > 5;
    const lag = fast ? 2.2 : 0.9;
    const bound = fast ? 320 : 170;
    cam += ((m - cam) / FPS) / lag;
    if (m - cam > bound) cam = m - bound;
    if (cam - m > bound) cam = m + bound;
    p0 += ((m - p0) / FPS) / 2.0;
    const lean = leanAt(tau);
    lb += (((lean === 1 ? 1 : 0) - lb) / FPS) / 0.2;
    la += (((lean === 2 ? 1 : 0) - la) / FPS) / 0.2;
    const target = Math.min(1, mapStep(tau) / 13_000_000);
    amp += ((target - amp) / FPS) / (target > amp ? 0.3 : 2.5);
  }
}
const FLIPS: { t: number; side: "bid" | "ask" }[] = [];
for (let f = 1; f < DURATION; f++) {
  if ((LB[f] > 0.5) !== (LB[f - 1] > 0.5)) FLIPS.push({ t: f / FPS, side: "bid" });
  if ((LA[f] > 0.5) !== (LA[f - 1] > 0.5)) FLIPS.push({ t: f / FPS, side: "ask" });
}

// ─── book texture ───────────────────────────────────────────────────────────
const lump = (k: number) => {
  const n1 = frac(Math.sin(k * 12.9898) * 43758.5453);
  const n2 = frac(Math.sin(k * 78.233) * 12345.678);
  if (n1 > 0.94) return 0.55 + n2 * 0.45;
  if (n1 > 0.76) return 0.2 + n2 * 0.3;
  return 0.05 + n2 * 0.12;
};
const LEVEL = 10;

const utc = (tau: number) => {
  const d = new Date((T0 + Math.floor(tau)) * 1000);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${p(d.getUTCHours())}:${p(d.getUTCMinutes())}:${p(d.getUTCSeconds())}`;
};

export const Mechanism: React.FC = () => {
  const f = useCurrentFrame();
  const t = f / FPS;
  const tau = TAU[f];

  const mark = markAt(tau);
  const bid = bidAt(tau);
  const ask = askAt(tau);
  const spread = ask - bid;
  const oracle = oracleAt(tau);
  const disl = dislAt(tau);
  const depth = depthAt(tau);
  const cam = CAM[f];
  const p0 = P0[f];
  const lb = LB[f];
  const la = LA[f];
  const speed = speedAt(t);

  const ppd = mono([[60, 1.9], [100, 1.6], [200, 1.0], [300, 0.64], [500, 0.5], [760, 0.42]])(Math.max(60, Math.min(760, spread)));
  const x = (p: number) => CX + (p - cam) * ppd;

  // ─── the desk ─────────────────────────────────────────────────────────────
  const pb = deskBidAt(tau, lb);
  const pa = deskAskAt(tau, la);
  const sigma = 300;
  const cDesk = (p: number) => gauss((p - p0) / sigma);
  const foldB = p0 > pb ? (Phi((p0 - pb) / sigma) - 0.5) * 2 : 0;
  const foldA = p0 < pa ? (0.5 - Phi((p0 - pa) / sigma)) * 2 : 0;
  const spot = spotAt(tau);
  const perp = perpAt(t);
  const hB = (1 - lb) * (120 + 250 * foldB) + lb * (90 + 320 * Math.max(0, 1 - spot));
  const hA = (1 - la) * (120 + 250 * foldA) + la * (90 + 320 * Math.max(0.1, spot));
  const makersIn = smooth(lin(t, 1.8, 3.6));

  // ─── the rival: priced off the oracle at its last refresh, once a minute ──
  const m0 = minuteOf(tau);
  const postNow = tOracle(m0 * 60);
  const postPrev = tOracle(Math.max(0, m0 - 1) * 60);
  const pr = postPrev + (postNow - postPrev) * smooth(lin(t, filmAt(m0 * 60), filmAt(m0 * 60) + 0.35));
  let mr = 1;
  let bleed = 0;
  for (const [h, usd] of RIVAL_HITS) {
    const ft = filmAt(h);
    mr -= (0.8 * usd / RIVAL_TOTAL) * smooth(lin(t, ft + HIT_DUR * 0.8, ft + HIT_DUR + 0.2));
    const u = lin(t, ft + HIT_DUR * 0.7, ft + HIT_DUR + 0.45);
    if (u > 0 && u < 1) bleed = Math.max(bleed, Math.sin(Math.PI * u));
  }
  mr = Math.max(0.15, mr);
  const sigmaR = 110;

  // ─── book bars ────────────────────────────────────────────────────────────
  const bars: React.ReactNode[] = [];
  const bidLevel = Math.floor(bid / LEVEL) * LEVEL;
  const askLevel = Math.ceil(ask / LEVEL) * LEVEL;
  const barW = Math.max(3, LEVEL * ppd * 0.72);
  const heightOf = (p: number, i: number) =>
    (60 + lump(Math.round(p / LEVEL)) * BAR_MAX) * (0.4 + 0.6 * Math.exp(-i / 50)) * depth + 6;
  for (let i = 0; i < 400; i++) {
    const p = bidLevel - i * LEVEL;
    const px = x(p);
    if (px < -30) break;
    const h = heightOf(p, i);
    bars.push(<rect key={`b${i}`} x={px - barW / 2} y={BASE - h} width={barW} height={h} fill={BID} opacity={0.9} />);
  }
  for (let i = 0; i < 400; i++) {
    const p = askLevel + i * LEVEL;
    const px = x(p);
    if (px > W + 30) break;
    const h = heightOf(p, i);
    bars.push(<rect key={`a${i}`} x={px - barW / 2} y={BASE - h} width={barW} height={h} fill={ASK} opacity={0.75} />);
  }

  // levels taken by forced flow in the last 1.2 film-seconds: red where they stood, collapsing
  const ghosts: React.ReactNode[] = [];
  const lagTau = TAU[Math.max(0, f - Math.round(1.2 * FPS))];
  const bidLag = bidAt(lagTau);
  const askLag = askAt(lagTau);
  if (forcedSellAt(tau) && bidLag > bid + 2.5 * LEVEL) {
    for (let p = bidLevel + LEVEL; p <= Math.min(bidLag, ask - LEVEL); p += LEVEL) {
      const age = (p - bid) / (bidLag - bid);
      const h = heightOf(p, 0) * (1 - 0.8 * age);
      ghosts.push(<rect key={`g${p}`} x={x(p) - barW / 2} y={BASE - h} width={barW} height={h} fill={EATEN} opacity={0.85 * (1 - age * 0.7)} />);
    }
  }
  if (forcedBuyAt(tau) && askLag < ask - 2.5 * LEVEL) {
    for (let p = askLevel - LEVEL; p >= Math.max(askLag, bid + LEVEL); p -= LEVEL) {
      const age = (ask - p) / (ask - askLag);
      const h = heightOf(p, 0) * (1 - 0.8 * age);
      ghosts.push(<rect key={`h${p}`} x={x(p) - barW / 2} y={BASE - h} width={barW} height={h} fill={EATEN} opacity={0.85 * (1 - age * 0.7)} />);
    }
  }

  // ─── the liquidation map ──────────────────────────────────────────────────
  const mapAmp = MAPAMP[f];
  let mapPath = "";
  if (mapAmp > 0.01) {
    const pts: string[] = [];
    for (let px = 0; px <= x(mark); px += 6) {
      const p = cam + (px - CX) / ppd;
      const bps = ((mark - p) / mark) * 1e4;
      const dens = mapAmp * gauss((bps - 35) / 22) + mapAmp * 0.55 * gauss((bps - 78) / 26);
      pts.push(`${px},${BASE - dens * 165}`);
    }
    mapPath = `M0,${BASE} L${pts.join(" L")} L${x(mark)},${BASE} Z`;
  }

  const left = cam - CX / ppd;
  const right = cam + CX / ppd;
  const humpPath = (from: number, to: number, fn: (p: number) => number, scale: number) => {
    const pts: string[] = [];
    const step = 4 / ppd;
    for (let p = from; p <= to; p += step) pts.push(`${x(p)},${BASE - fn(p) * scale}`);
    if (pts.length < 2) return "";
    return `M${x(from)},${BASE} L${pts.join(" L")} L${x(to)},${BASE} Z`;
  };
  const ghostPath = humpPath(Math.max(left, p0 - 3.5 * sigma), Math.min(right, p0 + 3.5 * sigma), cDesk, 95);
  const rivalPath = humpPath(pr - 3.5 * sigmaR, pr + 3.5 * sigmaR, (p) => gauss((p - pr) / sigmaR), 200 * mr);

  // ─── sparks ───────────────────────────────────────────────────────────────
  const sparks: React.ReactNode[] = [];
  for (const [h, usd] of RIVAL_HITS) {
    const ft = filmAt(h);
    if (t < ft || t > ft + HIT_DUR + 0.6) continue;
    const u = lin(t, ft, ft + HIT_DUR);
    const touch = pr > mark ? ask : bid;
    const sx = x(touch) + (x(pr) - x(touch)) * smooth(u);
    const sy = BASE - 120 - 60 * Math.sin(Math.PI * u);
    const r = 4 + 0.7 * Math.sqrt(usd);
    if (u < 1) sparks.push(<circle key={`s${h}`} cx={sx} cy={sy} r={r} fill={SPARK} filter="url(#glow)" />);
    const v = lin(t, ft + HIT_DUR, ft + HIT_DUR + 0.55);
    if (v > 0 && v < 1) {
      const fx = x(pr) + (1780 - x(pr)) * smooth(v);
      const fy = BASE - 200 * mr + (200 - (BASE - 200 * mr)) * smooth(v);
      sparks.push(<circle key={`f${h}`} cx={fx} cy={fy} r={4} fill={RIVAL} opacity={1 - v * 0.3} />);
    }
  }
  const check = (h: number, target: number, touch: number, key: string) => {
    const ft = filmAt(h);
    if (t < ft || t > ft + HIT_DUR + 0.3) return;
    const u = lin(t, ft, ft + HIT_DUR);
    const sx = x(touch) + (x(target) - x(touch)) * smooth(u);
    const sy = BASE - 120 - 60 * Math.sin(Math.PI * u);
    const fade = 1 - lin(t, ft + HIT_DUR, ft + HIT_DUR + 0.3);
    sparks.push(<circle key={key} cx={sx} cy={sy} r={7 * (0.4 + 0.6 * fade)} fill={u < 1 ? SPARK : INK} opacity={fade} filter="url(#glow)" />);
  };
  for (const h of DESK_CHECKS) {
    const up = markAt(h) > markAt(Math.max(0, h - (h < 60 ? 3 : 60)));
    check(h, up ? pa : pb, up ? ask : bid, `d${h}`);
  }
  for (const h of RIVAL_CHECKS) check(h, pr, pr > mark ? ask : bid, `rc${h}`);

  const coverPulses: React.ReactNode[] = [];
  for (const c of COVERS) {
    const ft = filmAt(c);
    const u = lin(t, ft + COVER_DELAY, ft + COVER_DELAY + 0.7);
    if (u <= 0 || u >= 1) continue;
    const sells = -spotAt(c) < perpAtTau(c - 1);
    const px = x(sells ? bid : ask);
    coverPulses.push(
      <g key={`c${c}`} opacity={1 - u}>
        <circle cx={px} cy={BASE - 70} r={12 + 110 * u} fill="none" stroke={HERO} strokeWidth={2.5} />
        <circle cx={px} cy={BASE - 70} r={8} fill={HERO} filter="url(#glow)" />
      </g>
    );
  }

  const rings: React.ReactNode[] = [];
  let pulse = 0;
  for (const fl of FLIPS) {
    const u = lin(t, fl.t, fl.t + 0.7);
    if (u <= 0 || u >= 1) continue;
    pulse = Math.max(pulse, Math.sin(Math.PI * u));
    const px = x(fl.side === "bid" ? pb : pa);
    const hh = fl.side === "bid" ? hB : hA;
    rings.push(<circle key={`r${fl.t}`} cx={px} cy={BASE - hh / 2} r={20 + 170 * u} fill="none" stroke={HERO} strokeWidth={3 * (1 - u)} opacity={1 - u} />);
  }
  const tokenSize = 21 + 9 * pulse;

  // ─── labels and axes ──────────────────────────────────────────────────────
  const label: React.CSSProperties = { fontFamily: SERIF, fontSize: 22, fill: INK };
  const monoS: React.CSSProperties = { fontFamily: MONO, fontSize: 18, fill: INK };

  const tickStep = ppd > 1.5 ? 100 : 500;
  const ticks: React.ReactNode[] = [];
  for (let p = Math.floor(left / tickStep) * tickStep; p <= right; p += tickStep) {
    const px = x(p);
    if (px < 40 || px > W - 40) continue;
    ticks.push(
      <g key={`t${p}`} opacity={0.5}>
        <line x1={px} y1={BASE} x2={px} y2={BASE + 8} stroke={INK} strokeWidth={1} />
        <text x={px} y={BASE + 30} style={{ ...monoS, fontSize: 15 }} textAnchor="middle">{p.toLocaleString("en-US")}</text>
      </g>
    );
  }
  const tokenB = lb > 0.5 ? "max" : "min";
  const tokenA = la > 0.5 ? "max" : "min";
  const tokenHot = (l: number) => l > 0.05 && l < 0.95;

  // ─── title block: instrument, clock, speed, timeline ──────────────────────
  const speedShown = speed < 1.5 ? 1 : Math.round(speed);
  const TLX0 = 70;
  const TLX1 = 390;
  const TLY = 214;
  const tlx = (s: number) => TLX0 + (Math.min(AXIS_END, s) / AXIS_END) * (TLX1 - TLX0);
  const shade: React.ReactNode[] = [];
  const runLabels: React.ReactNode[] = [];
  {
    let runStart = -1;
    let runLean = 0;
    let named = { 1: false, 2: false } as Record<number, boolean>;
    for (let s = 0; s <= AXIS_END; s += 15) {
      const l = s < AXIS_END && s < TAPE_END ? leanAt(s) : 0;
      if (l !== runLean) {
        if (runLean) {
          shade.push(<rect key={`sh${runStart}`} x={tlx(runStart)} y={TLY - 6} width={tlx(s) - tlx(runStart)} height={12} fill={HERO} opacity={runLean === 1 ? 0.55 : 0.3} />);
          if (!named[runLean] && s - runStart >= 240) {
            named[runLean] = true;
            runLabels.push(
              <text key={`rl${runStart}`} x={(tlx(runStart) + tlx(s)) / 2} y={TLY - 12} style={{ ...label, fontSize: 15, fill: HERO }} textAnchor="middle" opacity={runLean === 1 ? 0.9 : 0.7}>
                {runLean === 1 ? "cascade" : "rebound"}
              </text>
            );
          }
        }
        runStart = s;
        runLean = l;
      }
    }
  }

  // ─── panels: four strips on the timeline's own axis ──────────────────────
  const PW = 300;
  const PH = 150;
  const PY = 80;
  const panelX = (i: number) => 490 + i * (PW + 50);
  const panelsIn = (i: number) => smooth(lin(t, 1.0 + i * 0.25, 2.0 + i * 0.25));
  const N = 210;
  const px_ = (s: number) => (Math.min(AXIS_END, s) / AXIS_END) * PW;
  const samples: number[] = [];
  for (let k = 0; k <= N; k++) {
    const s = (AXIS_END * k) / N;
    if (s > tau) break;
    samples.push(s);
  }
  if (samples[samples.length - 1] !== tau) samples.push(Math.min(tau, AXIS_END));
  const poly = (ys: (s: number) => number, y: (v: number) => number) => samples.map((s, i) => `${i ? "L" : "M"}${px_(s)},${y(ys(s))}`).join(" ");
  const bandPath = (top: (s: number) => number, bot: (s: number) => number, y: (v: number) => number) =>
    poly(top, y) + " " + [...samples].reverse().map((s) => `L${px_(s)},${y(bot(s))}`).join(" ") + " Z";
  const wedges = (cond: (s: number) => boolean, top: (s: number) => number, bot: (s: number) => number, y: (v: number) => number, fill: string) => {
    const out: React.ReactNode[] = [];
    for (let i = 0; i < samples.length - 1; i++) {
      const s = samples[i];
      if (!cond(s)) continue;
      const y0 = y(top(s));
      const y1 = y(bot(s));
      out.push(<rect key={`w${i}`} x={px_(s)} y={Math.min(y0, y1)} width={Math.max(1.2, px_(samples[i + 1]) - px_(s) + 0.4)} height={Math.abs(y1 - y0)} fill={fill} opacity={0.85} />);
    }
    return out;
  };
  const playhead = px_(tau);

  const midAt = (s: number) => (bidAt(s) + askAt(s)) / 2;
  const bps = (p: number, s: number) => ((p - midAt(s)) / midAt(s)) * 1e4;
  const lbAt = (s: number) => (leanAt(s) === 1 ? 1 : 0);
  const laAt = (s: number) => (leanAt(s) === 2 ? 1 : 0);
  const y1 = (v: number) => PH / 2 - (v / 55) * (PH / 2 - 10);
  const l1b = (s: number) => bps(bidAt(s), s);
  const l1a = (s: number) => bps(askAt(s), s);
  const dkb = (s: number) => bps(deskBidAt(s, lbAt(s)), s);
  const dka = (s: number) => bps(deskAskAt(s, laAt(s)), s);
  const y2 = (v: number) => PH / 2 - (v / 90) * (PH / 2 - 8);
  const y3 = (v: number) => PH / 2 - v * (PH / 2 - 14);
  const fillDots: React.ReactNode[] = [];
  for (let m = 0; m < TAPE.absorbedDesk.length; m++) {
    const a = TAPE.absorbedDesk[m];
    if (!a) continue;
    const s = m * 60 + 25;
    if (s > tau) continue;
    const p = TAPE.lean[m] === 2 ? TAPE.deskAsk[m] : TAPE.deskBid[m];
    const d = ((TAPE.oracle[m] - p) / TAPE.oracle[m]) * 1e4;
    fillDots.push(<circle key={`fd${m}`} cx={px_(s)} cy={y2(d)} r={2.5 + 0.06 * Math.sqrt(a)} fill={HERO} opacity={0.9} />);
  }
  const absorbed = absorbedAt(tau);
  const TAKEN_MAX = 260;
  const y4 = (v: number) => PH - 12 - (v / TAKEN_MAX) * (PH - 40);
  const taken = takenAt(tau);

  const wordmark = smooth(lin(t, 50.5, 52.5));

  return (
    <AbsoluteFill style={{ background: BG }}>
      <svg width={W} height={H}>
        <defs>
          <filter id="glow" x="-100%" y="-100%" width="300%" height="300%">
            <feGaussianBlur stdDeviation="6" result="b" />
            <feMerge>
              <feMergeNode in="b" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
          <filter id="soft" x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur stdDeviation="10" result="b" />
            <feMerge>
              <feMergeNode in="b" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
        </defs>

        {/* ─── title block ─── */}
        <g opacity={smooth(lin(t, 0.3, 1.3))}>
          <text x={TLX0} y={100} style={{ ...label, fontSize: 27 }} opacity={0.85}>BTC perpetual · Hyperliquid</text>
          <text x={TLX0} y={150} style={{ ...monoS, fontSize: 34, fill: WHITE }}>{utc(tau)}</text>
          <text x={TLX0 + 176} y={150} style={{ ...label, fontSize: 19 }} opacity={0.7}>UTC</text>
          <text x={TLX1} y={150} style={{ ...monoS, fontSize: 24, fill: speedShown > 1 ? HERO : INK }} textAnchor="end" opacity={speedShown > 1 ? 1 : 0.6}>
            ×{speedShown}
          </text>
          <text x={TLX0} y={181} style={{ ...label, fontSize: 19 }} opacity={0.7}>10 October 2025</text>
          <line x1={TLX0} y1={TLY} x2={TLX1} y2={TLY} stroke={INK} strokeWidth={1.2} opacity={0.5} />
          {shade}
          {runLabels}
          <line x1={tlx(tau)} y1={TLY - 10} x2={tlx(tau)} y2={TLY + 10} stroke={WHITE} strokeWidth={2} />
          <text x={TLX0} y={TLY + 28} style={{ ...monoS, fontSize: 13 }} opacity={0.6}>21:03</text>
          <text x={TLX1} y={TLY + 28} style={{ ...monoS, fontSize: 13 }} textAnchor="end" opacity={0.6}>21:38</text>
        </g>

        {/* ─── stage ─── */}
        {mapPath && <path d={mapPath} fill={MAP} opacity={0.34} />}
        <line x1={0} y1={BASE} x2={W} y2={BASE} stroke={INK2} strokeWidth={2} />
        <g opacity={smooth(lin(t, 0.2, 1.4))}>{bars}</g>
        {ghosts}
        {ticks}

        <g opacity={mono([[0, 0], [1.4, 0], [2.4, 0.7], [6, 0.7], [7.5, 0.3]])(t)}>
          <text x={120} y={BASE + 66} style={{ ...label, fill: BID }} textAnchor="start">bids</text>
          <text x={W - 120} y={BASE + 66} style={{ ...label, fill: ASK }} textAnchor="end">asks</text>
        </g>
        <g opacity={smooth(lin(t, 1.0, 2.0))}>
          <line x1={x(bid)} y1={BASE + 56} x2={x(ask)} y2={BASE + 56} stroke={spread > 250 ? EATEN : INK} strokeWidth={1.5} opacity={0.8} />
          <line x1={x(bid)} y1={BASE + 48} x2={x(bid)} y2={BASE + 64} stroke={spread > 250 ? EATEN : INK} strokeWidth={1.5} opacity={0.8} />
          <line x1={x(ask)} y1={BASE + 48} x2={x(ask)} y2={BASE + 64} stroke={spread > 250 ? EATEN : INK} strokeWidth={1.5} opacity={0.8} />
          <text x={(x(bid) + x(ask)) / 2} y={BASE + 92} style={{ ...monoS, fontSize: 20, fill: spread > 250 ? EATEN : INK }} textAnchor="middle">
            {Math.round(spread)}
          </text>
        </g>

        {/* rival */}
        <g opacity={makersIn}>
          <path d={rivalPath} fill={RIVAL} opacity={0.4} />
          <path d={rivalPath} fill={SPARK} opacity={0.4 * bleed} />
          <path d={rivalPath} fill="none" stroke={RIVAL} strokeWidth={1.5} opacity={0.95} />
          <line x1={x(pr)} y1={BASE - 200 * mr - 6} x2={x(pr)} y2={BASE - 252} stroke={RIVAL} strokeWidth={1} opacity={0.5} />
          <text x={x(pr)} y={BASE - 262} style={{ ...label, fill: RIVAL, fontSize: 24 }} textAnchor="middle">
            oracle-pegged AMM
          </text>
        </g>

        {/* desk */}
        <g opacity={makersIn}>
          <path d={ghostPath} fill={HERO} opacity={0.045} />
          <path d={ghostPath} fill="none" stroke={HERO} strokeWidth={1.3} strokeDasharray="5 7" opacity={0.5} />
          <rect x={x(pb) - 7} y={BASE - hB} width={14} height={hB} fill={HERO} filter={lb > 0.05 ? "url(#soft)" : undefined} opacity={0.95} />
          <text x={x(pb)} y={BASE - hB - 40} style={{ ...monoS, fill: tokenHot(lb) ? WHITE : HERO, fontSize: tokenHot(lb) ? tokenSize : 21 }} textAnchor="middle" opacity={0.95}>{tokenB}</text>
          <text x={x(pb)} y={BASE - hB - 14} style={{ ...label, fill: HERO, fontSize: 20 }} textAnchor="middle">desk bid</text>
          <rect x={x(pa) - 7} y={BASE - hA} width={14} height={hA} fill={HERO} filter={la > 0.05 ? "url(#soft)" : undefined} opacity={0.95} />
          <text x={x(pa)} y={BASE - hA - 40} style={{ ...monoS, fill: tokenHot(la) ? WHITE : HERO, fontSize: tokenHot(la) ? tokenSize : 21 }} textAnchor="middle" opacity={0.95}>{tokenA}</text>
          <text x={x(pa)} y={BASE - hA - 14} style={{ ...label, fill: HERO, fontSize: 20 }} textAnchor="middle">desk ask</text>
        </g>

        {/* mark and oracle */}
        <g opacity={smooth(lin(t, 0.8, 1.8))}>
          <line x1={x(mark)} y1={300} x2={x(mark)} y2={BASE} stroke={MARK} strokeWidth={1.5} strokeDasharray="3 7" opacity={0.7} />
          <text x={x(mark) + (oracle >= mark ? -9 : 9)} y={292} style={{ ...label, fill: MARK, fontSize: 20 }} textAnchor={oracle >= mark ? "end" : "start"} opacity={0.85}>mark</text>
          <line x1={x(oracle)} y1={300} x2={x(oracle)} y2={BASE} stroke={ORACLE} strokeWidth={1} opacity={0.75} />
          <text x={x(oracle) + (oracle >= mark ? 9 : -9)} y={292} style={{ ...label, fill: ORACLE, fontSize: 20 }} textAnchor={oracle >= mark ? "start" : "end"} opacity={0.85}>oracle</text>
        </g>

        {sparks}
        {coverPulses}
        {rings}

        {/* ─── panels ─── */}
        <g transform={`translate(${panelX(0)},${PY})`} opacity={panelsIn(0)}>
          <text x={0} y={-14} style={label} fontSize={17} opacity={0.75}>the two books</text>
          <line x1={0} y1={PH} x2={PW} y2={PH} stroke={INK2} strokeWidth={1} />
          <line x1={0} y1={y1(0)} x2={PW} y2={y1(0)} stroke={INK} strokeWidth={1} strokeDasharray="2 5" opacity={0.35} />
          <path d={bandPath(dka, dkb, y1)} fill={HERO} opacity={0.14} />
          <path d={bandPath(l1a, l1b, y1)} fill={L1} opacity={0.7} />
          {wedges((s) => dkb(s) > l1b(s), dkb, l1b, y1, HERO)}
          {wedges((s) => dka(s) < l1a(s), dka, l1a, y1, TEAL)}
          <path d={poly(dkb, y1)} fill="none" stroke={HERO} strokeWidth={1.3} opacity={0.9} />
          <path d={poly(dka, y1)} fill="none" stroke={HERO} strokeWidth={1.3} opacity={0.9} />
          <line x1={playhead} y1={0} x2={playhead} y2={PH} stroke={WHITE} strokeWidth={1} opacity={0.35} />
        </g>

        <g transform={`translate(${panelX(1)},${PY})`} opacity={panelsIn(1)}>
          <text x={0} y={-14} style={label} fontSize={17} opacity={0.75}>oracle − mark</text>
          <line x1={0} y1={PH} x2={PW} y2={PH} stroke={INK2} strokeWidth={1} />
          <rect x={0} y={0} width={PW} height={y2(STRESS)} fill={HERO} opacity={0.07} />
          <rect x={0} y={y2(-STRESS)} width={PW} height={PH - y2(-STRESS)} fill={HERO} opacity={0.07} />
          <line x1={0} y1={y2(STRESS)} x2={PW} y2={y2(STRESS)} stroke={HERO} strokeWidth={1} opacity={0.6} />
          <line x1={0} y1={y2(-STRESS)} x2={PW} y2={y2(-STRESS)} stroke={HERO} strokeWidth={1} opacity={0.6} />
          <line x1={0} y1={y2(0)} x2={PW} y2={y2(0)} stroke={INK} strokeWidth={1} strokeDasharray="2 5" opacity={0.35} />
          <path d={poly(dislAt, y2)} fill="none" stroke={ORACLE} strokeWidth={1.6} opacity={0.95} />
          {fillDots}
          {fillDots.length > 0 && <text x={PW - 4} y={14} style={{ ...label, fontSize: 13, fill: HERO }} textAnchor="end" opacity={0.85}>desk fills</text>}
          <circle cx={playhead} cy={y2(disl)} r={4} fill={lb > 0.5 || la > 0.5 ? HERO : WHITE} />
          <text x={-8} y={y2(STRESS) + 5} style={{ ...monoS, fontSize: 12, fill: HERO }} textAnchor="end" opacity={0.7}>+25</text>
          <text x={-8} y={y2(-STRESS) + 5} style={{ ...monoS, fontSize: 12, fill: HERO }} textAnchor="end" opacity={0.7}>−25</text>
          <text x={PW} y={-14} style={{ ...monoS, fontSize: 17, fill: lb > 0.5 || la > 0.5 ? HERO : INK }} textAnchor="end">
            {Math.round(disl) > 0 ? "+" : Math.round(disl) < 0 ? "−" : ""}{Math.abs(Math.round(disl))} bps
          </text>
        </g>

        <g transform={`translate(${panelX(2)},${PY})`} opacity={panelsIn(2)}>
          <text x={0} y={-14} style={label} fontSize={17} opacity={0.75}>position</text>
          <text x={PW} y={-14} style={{ ...monoS, fontSize: 17, fill: HERO }} textAnchor="end" opacity={absorbed > 0 ? 1 : 0}>
            absorbed ${Math.round(absorbed).toLocaleString("en-US")}
          </text>
          <line x1={0} y1={PH} x2={PW} y2={PH} stroke={INK2} strokeWidth={1} />
          <line x1={0} y1={y3(0)} x2={PW} y2={y3(0)} stroke={INK} strokeWidth={1} opacity={0.5} />
          <line x1={0} y1={y3(1)} x2={PW} y2={y3(1)} stroke={HERO} strokeWidth={1} strokeDasharray="3 5" opacity={0.5} />
          <path d={bandPath(spotAt, () => 0, y3)} fill={HERO} opacity={0.75} />
          <path d={bandPath(() => 0, perpAtTau, y3)} fill={MARK} opacity={0.6} />
          <path d={poly((s) => spotAt(s) + perpAtTau(s), y3)} fill="none" stroke={WHITE} strokeWidth={1.4} opacity={0.9} />
          <text x={-8} y={y3(1) + 5} style={{ ...label, fontSize: 13, fill: HERO }} textAnchor="end" opacity={0.7}>band</text>
          <text x={6} y={y3(0.72) + 5} style={{ ...label, fontSize: 15, fill: WHITE }} opacity={0.85}>spot · desk</text>
          <text x={6} y={y3(-0.72) + 5} style={{ ...label, fontSize: 15, fill: WHITE }} opacity={0.85}>perp · HyperCore</text>
          <text x={-8} y={y3(0) + 5} style={{ ...label, fontSize: 13, fill: WHITE }} textAnchor="end" opacity={0.6}>net</text>
        </g>

        <g transform={`translate(${panelX(3)},${PY})`} opacity={panelsIn(3)}>
          <text x={0} y={-14} style={label} fontSize={17} opacity={0.75}>taken by arbitrage</text>
          <line x1={0} y1={PH} x2={PW} y2={PH} stroke={INK2} strokeWidth={1} />
          <path d={poly(takenAt, y4)} fill="none" stroke={RIVAL} strokeWidth={1.8} />
          <path d={poly(() => 0, y4)} fill="none" stroke={HERO} strokeWidth={2.2} />
          <text x={Math.min(playhead + 8, PW - 70)} y={y4(taken) - 8} style={{ ...monoS, fontSize: 18, fill: RIVAL }}>${Math.round(taken).toLocaleString("en-US")}</text>
          <text x={Math.min(playhead + 8, PW - 70)} y={y4(0) + 22} style={{ ...monoS, fontSize: 18, fill: HERO }}>$0</text>
        </g>

        <text x={CX} y={1044} style={{ ...label, fontSize: 38, fill: HERO }} textAnchor="middle" opacity={wordmark}>
          coldcascade
        </text>
      </svg>
    </AbsoluteFill>
  );
};
