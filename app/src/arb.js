// What an arbitrageur would get for trying, computed from the frame that is on the screen.
//
// A maker is arbitraged when somebody can buy from it and sell at the reference venue for more
// than they paid. That profit is the maker's loss-versus-rebalancing, and it exists because the
// maker's price was set at some earlier moment than the trade that takes it. Every AMM has that
// gap; it is the whole of LVR and most of what an LP pays for the privilege of quoting.
//
// This desk has no earlier moment. `CoreQuote` reads 0x080e inside the call that settles the swap
// and the last thing it does is clamp itself to what crossing L1 would have paid. So the round
// trip is not an estimate here, it is arithmetic on two prices out of the same eth_call:
//
//   sell to the desk   give 1 base, receive bidPx quote, buy the base back at L1's ask
//                      → (bidPx − ask) / ask
//   buy from the desk  pay askPx quote for 1 base, sell it into L1's bid
//                      → (bid − askPx) / askPx
//
// Both are negative in the quiet by the desk's own band plus the L1 spread the exit has to cross.
// Both are zero, never positive, when the desk is leaning — because the lean is clamped at L1's
// own price on that side. `test/Inarbitrable.t.sol` is the same round trip asserted against the
// contract itself, fuzzed over books, sides, exactness and curves; this is that property with
// today's book in it.
//
// Two things it deliberately does not model, both in the arbitrageur's favour: the exit is priced
// at L1's touch with infinite depth, and it pays no fee. A real exit is worse than this on both
// counts, so a real round trip is further under water than the number on the screen.

/** The two directions and the L1 spread, in bps. Null when this desk has no price right now. */
export function roundTrip(book, desk) {
  if (!desk.quoted) return null;
  const bid = Number(book.bid);
  const ask = Number(book.ask);
  const deskBid = Number(desk.bidPx);
  const deskAsk = Number(desk.askPx);
  if (!(bid > 0 && ask > 0 && deskBid > 0 && deskAsk > 0)) return null;

  const sellToDesk = ((deskBid - ask) / ask) * 10_000;
  const buyFromDesk = ((bid - deskAsk) / deskAsk) * 10_000;
  return {
    sellToDesk,
    buyFromDesk,
    best: Math.max(sellToDesk, buyFromDesk),
    l1SpreadBps: ((ask - bid) / ((ask + bid) / 2)) * 10_000,
    prices: { bid, ask, deskBid, deskAsk },
  };
}

/** The best round trip available anywhere on this screen, and the desk it is against. */
export function bestRoundTrip(book, desks) {
  let best = null;
  for (const desk of desks) {
    const trip = roundTrip(book, desk);
    if (trip && (best === null || trip.best > best.trip.best)) best = { desk, trip };
  }
  return best;
}

/**
 * The ablated control, live: a plain constant-product curve on this desk's own reserves, the bound
 * removed, searched over size against the same book.
 *
 * That is the toll the zero next to it is compared against — the same arbitrageur, the same exit
 * prices, the same reserves, one instruction fewer. It is computed from the frame on the screen
 * rather than quoted from a past block, so it breathes with the book: the point the pair of numbers
 * makes is that the toll moves every block and the desk's zero does not.
 *
 * Sizes are fractions of the curve's own depth, which is the honest way to search a thin curve: a
 * clip that is most of the reserve pays a terrible average price, so the best clip is usually
 * small and the bps is the story, not the dollars. Base is UBTC (8 decimals) and quote is USDT0
 * (6) on every desk this floor lists; BBO raw is tenths of a dollar.
 */
export function controlToll(book, desk) {
  const B = Number(desk.baseBalance) / 1e8;
  const Q = Number(desk.quoteBalance) / 1e6;
  const bid = Number(book.bid) / 10;
  const ask = Number(book.ask) / 10;
  if (!(B > 0 && Q > 0 && bid > 0 && ask > 0)) return null;

  let best = { usd: 0, bps: 0 };
  for (const f of [0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.4]) {
    const x = B * f;
    // Buy at L1's ask, sell into the curve — pays when the curve's ratio sits above the book.
    const sellProfit = (Q * x) / (B + x) - x * ask;
    if (sellProfit > best.usd) best = { usd: sellProfit, bps: (sellProfit / (x * ask)) * 10_000 };
    // Buy from the curve, sell into L1's bid — pays when the ratio sits below it.
    const cost = (Q * x) / (B - x);
    const buyProfit = x * bid - cost;
    if (buyProfit > best.usd) best = { usd: buyProfit, bps: (buyProfit / cost) * 10_000 };
  }
  return best;
}

/** The worst toll on the screen — the curve an arbitrageur would start with. */
export function bestControlToll(book, desks) {
  let best = null;
  for (const desk of desks) {
    if (!desk.account || BigInt(desk.account) === 0n) continue;
    const toll = controlToll(book, desk);
    if (toll && (best === null || toll.usd > best.usd)) best = toll;
  }
  return best;
}
