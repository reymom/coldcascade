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

export interface ReplayRow {
  t: number;
  pnlControlBps: number;
  pnlDeskBps: number;
  baseControl: bigint;
  baseDesk: bigint;
  lean: Side;
  absorbedNtl: bigint;
}
