// Mirrors src/libs/DeskParams.sol, src/interfaces/ICoreReader.sol and src/libs/Regime.sol.
// Raw L1 prices are integers: USD * 10^(6 - szDecimals). BTC: USD * 10.

export type Address = `0x${string}`;

export interface Book {
  bid: bigint;
  ask: bigint;
  mark: bigint;
  oracle: bigint;
}

export interface LiquidationMap {
  belowNotional: bigint;
  aboveNotional: bigint;
  updatedAt: bigint;
}

export type Side = "none" | "bid" | "ask";

export interface Regime {
  lean: Side;
  dislocationBps: bigint;
  mapBelow: bigint;
  mapAbove: bigint;
  mapFresh: boolean;
}

export interface DeskParams {
  base: Address;
  quote: Address;
  perpIndex: number;
  pxNum: bigint;
  pxDen: bigint;
  quietBps: number;
  leanBps: number;
  stressBps: number;
  mapOracle: Address;
  mapMaxAge: number;
  mapMinNotional: bigint;
  minBase: bigint;
  maxBase: bigint;
}

export interface DeskQuote {
  bidPx: bigint;
  askPx: bigint;
  lean: Side;
}

/// One row of results/oct10_replay.csv. Field order is the CSV column order and is frozen;
/// results/oct10_replay.schema.md carries the units. Prices are raw HyperCore integers, notionals
/// are whole USD, base is UBTC(8) units, quote is USDT0(6) units, bps are signed integers.
export interface ReplayRow {
  t: number;
  spot: bigint;
  bid: bigint;
  ask: bigint;
  mark: bigint;
  oracle: bigint;
  deskBid: bigint;
  deskAsk: bigint;
  lean: Side;
  dislocationBps: number;
  mapBelowNtl: bigint;
  mapAboveNtl: bigint;
  forcedSellNtl: bigint;
  forcedBuyNtl: bigint;
  baseDesk: bigint;
  quoteDesk: bigint;
  baseControl: bigint;
  quoteControl: bigint;
  pnlDeskBps: number;
  pnlControlBps: number;
  absorbedDeskNtl: bigint;
  absorbedControlNtl: bigint;
  arbDeskNtl: bigint;
  arbControlNtl: bigint;
  markoutDesk5mBps: number;
  markoutDesk15mBps: number;
  markoutDesk60mBps: number;
  markoutControl5mBps: number;
  markoutControl15mBps: number;
  markoutControl60mBps: number;
  baseHard: bigint;
  quoteHard: bigint;
  pnlHardBps: number;
  absorbedHardNtl: bigint;
  arbHardNtl: bigint;
  markoutHard5mBps: number;
  markoutHard15mBps: number;
  markoutHard60mBps: number;
  absorbedTouchNtl: bigint;
  markoutTouch5mBps: number;
  markoutTouch15mBps: number;
  markoutTouch60mBps: number;
  lvrDeskNtl: bigint;
  lvrControlNtl: bigint;
  lvrHardNtl: bigint;
}

/// The CSV header, verbatim. `test_replay_writesResults` pins the same string on the Solidity
/// side, so a column added on one side and not the other fails the suite rather than the page.
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
] as const;

/// 0 none, 1 bid, 2 ask — how `lean` is written in the CSV.
export const LEAN_FROM_CSV: readonly Side[] = ["none", "bid", "ask"];
