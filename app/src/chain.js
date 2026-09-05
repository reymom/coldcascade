// The calls the Floor makes. One place, so every selector and every type string is checked once.

import { calldata, decode, encode } from "./abi.js";
import { Rpc, plant } from "./rpc.js";

/** The packed-as-a-tuple DeskParams. Same thirteen fields as src/libs/DeskParams.sol. */
export const PARAMS =
  "(address,address,uint32,uint64,uint64,uint16,uint16,uint16,address,uint32,uint128,uint128,uint128)";

const REGIME = "(uint8,int256,uint128,uint128,bool)";
const MAP = "(uint128,uint128,uint64)";
const BOOK = "(uint64,uint64,uint64,uint64)";

/** FloorLens.DeskView, field for field. */
const DESK_VIEW =
  `(address,string,address,bool,bytes32,${PARAMS},uint256,uint256,bool,uint256,uint256,uint8,${REGIME},${MAP},bool,bool,uint256,uint256)`;

/** FloorLens.FloorView. */
const FLOOR_VIEW = `(uint256,uint256,uint256,bool,${BOOK},uint64,${DESK_VIEW}[])`;

/**
 * Every selector the page sends comes from `app/selectors.json`, which `script/appdata.sh` writes
 * out of the compiled artifacts. None is typed here. A signature that drifts from the contract
 * fails that script rather than producing a call the router silently rejects — which is exactly how
 * a whole afternoon was lost to a router whose `quote` had two more arguments than the ABI in
 * `node_modules` (`results/999_router_abi.md`).
 */
export async function loadSelectors(base = ".") {
  const res = await fetch(`${base}/selectors.json`);
  if (!res.ok) throw new Error(`selectors.json: HTTP ${res.status}`);
  return res.json();
}

/** One eth_call behind the whole screen. */
export async function readFloor(rpc, { lens, coreQuote, perpIndex, accounts, previews, overrides, sel }) {
  const data = calldata(
    sel.floor,
    ["address", "uint32", "address[]", `${PARAMS}[]`],
    [coreQuote, perpIndex, accounts, previews],
  );
  const raw = await rpc.call({ to: lens, data, gas: "0x2faf080" }, overrides);
  const [v] = decode([FLOOR_VIEW], raw);
  return shapeFloor(v);
}

function shapeFloor(v) {
  const [chainId, blockNumber, timestamp, bookOk, book, l1Block, desks] = v;
  return {
    chainId: Number(chainId),
    blockNumber: Number(blockNumber),
    timestamp: Number(timestamp),
    bookOk,
    book: { bid: book[0], ask: book[1], mark: book[2], oracle: book[3] },
    l1Block: Number(l1Block),
    desks: desks.map(shapeDesk),
  };
}

function shapeDesk(d) {
  const [
    account, label, owner, open, strategyHash, params, baseBalance, quoteBalance,
    quoted, bidPx, askPx, lean, regime, map, hedgeArmed, coverIsBuy, coverBase, coverNotional,
  ] = d;
  return {
    account, label, owner, open, strategyHash,
    params: shapeParams(params),
    baseBalance, quoteBalance, quoted, bidPx, askPx,
    lean: Number(lean),
    regime: {
      lean: Number(regime[0]),
      dislocationBps: regime[1],
      mapBelow: regime[2],
      mapAbove: regime[3],
      mapFresh: regime[4],
    },
    map: { below: map[0], above: map[1], updatedAt: Number(map[2]) },
    hedgeArmed, coverIsBuy, coverBase, coverNotional,
  };
}

export function shapeParams(p) {
  const [base, quote, perpIndex, pxNum, pxDen, quietBps, leanBps, stressBps,
         mapOracle, mapMaxAge, mapMinNotional, minBase, maxBase] = p;
  return {
    base, quote,
    perpIndex: Number(perpIndex),
    pxNum, pxDen,
    quietBps: Number(quietBps),
    leanBps: Number(leanBps),
    stressBps: Number(stressBps),
    mapOracle,
    mapMaxAge: Number(mapMaxAge),
    mapMinNotional, minBase, maxBase,
  };
}

export function paramsTuple(p) {
  return [p.base, p.quote, p.perpIndex, p.pxNum, p.pxDen, p.quietBps, p.leanBps, p.stressBps,
          p.mapOracle, p.mapMaxAge, p.mapMinNotional, p.minBase, p.maxBase];
}

/** DeskAccount.order() — the order a taker swaps against, rebuilt by the account itself. */
export async function readOrder(rpc, sel, account) {
  const raw = await rpc.call({ to: account, data: sel.order });
  const [o] = decode(["(address,uint256,bytes)"], raw);
  return { maker: o[0], traits: o[1], data: o[2] };
}

/**
 * The taker traits a page sends, packed exactly as `TakerTraitsLib.build` does.
 *
 * Ten uint16 slice indexes, then a uint16 of flags, then the slices themselves. Only the threshold
 * slice is used, so every index is 32 and the tail is the threshold word.
 *
 * Flags: isExactIn 0x0001, useTransferFromAndAquaPush 0x0040. The push flag is what makes this a
 * page's swap rather than a contract's: the taker gives the router an ordinary ERC-20 approval and
 * the router pushes into Aqua on the maker's behalf.
 */
export function takerTraits({ isExactIn = true, minOut = 0n }) {
  const THRESHOLD = 32;
  const indexes = new Array(10).fill(THRESHOLD).map((n) => n.toString(16).padStart(4, "0")).join("");
  const flags = ((isExactIn ? 0x0001 : 0) | 0x0040).toString(16).padStart(4, "0");
  const threshold = minOut.toString(16).padStart(64, "0");
  return "0x" + indexes + flags + threshold;
}

export function quoteCall(sel, order, tokenIn, tokenOut, amount, traits) {
  return calldata(
    sel.quote,
    ["(address,uint256,bytes)", "address", "address", "uint256", "bytes"],
    [[order.maker, order.traits, order.data], tokenIn, tokenOut, amount, traits],
  );
}

export function swapCall(sel, order, tokenIn, tokenOut, amount, traits) {
  return calldata(
    sel.swap,
    ["(address,uint256,bytes)", "address", "address", "uint256", "bytes"],
    [[order.maker, order.traits, order.data], tokenIn, tokenOut, amount, traits],
  );
}

export const erc20 = {
  balanceOf: (sel, who) => calldata(sel.balanceOf, ["address"], [who]),
  allowance: (sel, owner, spender) => calldata(sel.allowance, ["address", "address"], [owner, spender]),
  approve: (sel, spender, amount) => calldata(sel.approve, ["address", "uint256"], [spender, amount]),
  mint: (sel, to, amount) => calldata(sel.mint, ["address", "uint256"], [to, amount]),
  decimals: (sel) => sel.decimals,
  symbol: (sel) => sel.symbol,
};

/** MapOracle / DemoMapOracle share this signature; only who may call it differs. */
export const mapUpdate = (sel, perpIndex, below, above) =>
  calldata(sel.update, ["uint32", "uint128", "uint128"], [perpIndex, below, above]);

export { Rpc, plant, encode, decode, calldata };
