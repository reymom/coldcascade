#!/usr/bin/env node
// What a take would return, without sending one.
//
// The page's quote line is the first honest number in the flow and it only appears after the gas
// drip and two transactions are already under way, so "is the bound biting right now?" was a
// question you could only answer by taking. It is one `eth_call`. This runs it from a terminal
// through the page's own modules — same selectors, same order, same encoding — so the number is
// the page's by construction rather than a second implementation that drifts from it.
//
//   node script/quote.mjs                 # the demo desk, buying base, the page's default size
//   node script/quote.mjs demo sell 0.001
//   node script/quote.mjs hedged buy 10
//
// Size is in the token the taker gives: base when selling base, quote when buying it.

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Rpc, readFloor, readOrder, quoteCall, takerTraits, paramsTuple, decode } from "../app/src/chain.js";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const json = async (p) => JSON.parse(await readFile(join(root, p), "utf8"));

const [which = "demo", side = "buy", size] = process.argv.slice(2);
const sellBase = side === "sell";

const deployment = await json("deployments/999.json");
const sel = await json("app/selectors.json");
const rpc = new Rpc([process.env.HYPEREVM_RPC_URL ?? "https://rpc.hyperliquid.xyz/evm"]);

const accounts = [deployment.canonicalDesk, deployment.demoDesk, deployment.hedgedDesk].filter(Boolean);
const account = deployment[`${which}Desk`];
if (!account) throw new Error(`no desk called ${which}`);

const floor = await readFloor(rpc, {
  lens: deployment.floorLens,
  coreQuote: deployment.coreQuote,
  perpIndex: 0,
  accounts,
  previews: [],
  overrides: undefined,
  sel,
});

const desk = floor.desks.find((d) => d.account.toLowerCase() === account.toLowerCase());
if (!desk) throw new Error(`the lens did not return ${which}`);

const decimalsIn = sellBase ? 8 : 6;
const units = (s, d) => BigInt(Math.round(Number(s) * 10 ** d));
const amountIn = units(size ?? (sellBase ? "0.001" : "10"), decimalsIn);
const [tokenIn, tokenOut] = sellBase ? [desk.params.base, desk.params.quote] : [desk.params.quote, desk.params.base];

const order = await readOrder(rpc, sel, account);
const traits = takerTraits({ isExactIn: true, minOut: 0n });
const quoted = await rpc.call({
  to: deployment.router,
  data: quoteCall(sel, order, tokenIn, tokenOut, amountIn, traits),
});
const [amountInQ, amountOut] = decode(["uint256", "uint256", "bytes32"], quoted);

// The same comparison the page prints: what crossing the book would have given at this size.
const crossing = sellBase
  ? amountIn * BigInt(floor.book.bid) * desk.params.pxNum / desk.params.pxDen
  : amountIn * desk.params.pxDen / (BigInt(floor.book.ask) * desk.params.pxNum);
const edge = crossing === 0n ? 0 : Number((amountOut - crossing) * 10_000n / crossing);

const usd = (raw) => (Number(raw) / 10).toLocaleString("en-US", { minimumFractionDigits: 1 });
const amount = (raw, d) => (Number(raw) / 10 ** d).toString();

console.log(`block ${floor.blockNumber}  ·  L1 bid ${usd(floor.book.bid)} / ask ${usd(floor.book.ask)}`);
console.log(`${which} desk, taker ${sellBase ? "sells" : "buys"} base, ${amount(amountIn, decimalsIn)} in`);
console.log(`quote: ${amount(amountOut, sellBase ? 6 : 8)} out  ·  crossing: ${amount(crossing, sellBase ? 6 : 8)}`);
console.log(`edge:  ${edge >= 0 ? "+" : ""}${edge} bps against crossing the book`);
console.log(Math.abs(Math.abs(edge) - 20) <= 1
  ? "the bound is biting — this is the take to record"
  : "the curve is pricing this, not the bound — the other side, or wait");
