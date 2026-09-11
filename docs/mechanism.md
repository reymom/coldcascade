# The mechanism

The long form of the README's *What it is*: the problem, the bound against the book the quote read, and the tests that assert it.

**When the market moves, bots charge AMMs for still using the old price. This maker reads the book
before it accepts the trade.**

A maker program on 1inch Aqua whose quote is computed from Hyperliquid's own order book inside the
call that settles the swap.

That is the problem it is built against. An automated market maker is arbitraged for the distance
between its price and the reference venue's, because its price was set before the trade that takes
it. The arbitrageur's profit is the LP's loss, it has a name — **loss-versus-rebalancing** — and
fees are what an LP has to cover it with. Fees shrink it and faster blocks shrink it, but nothing
in the shape of an AMM takes it to zero, because the gap between quoting and being taken is where
the whole construction lives.

A maker that reads the reference book in the same call closes that gap against that book. This one
reads it and then clamps itself to what crossing L1 would have paid, so a round trip that takes the
desk's price and closes it at the touch the quote just read comes back negative in the quiet by the
desk's own band, and exactly zero while it is leaning. That is the channel this attacks: extraction
against a price set before the trade, bounded in the call that settles it.

**HyperEVM is not the argument. It is where the argument is possible today** — the one chain with
1inch Aqua deployed and a perp book a contract can read in the same call: `0x0806` mark, `0x0807`
oracle, `0x080e` best bid and ask, as precompiles. Aqua's HyperEVM deployment has no makers. This
is the first program that quotes against that book.

The program is `XYCSwap || Extruction(CoreQuote)` on the official SwapVM router. `CoreQuote` reads
the book in the quote itself, and Aqua custodies nothing.

**Absorbing a liquidation cascade is the same property under stress**, and it is the consequence,
not the thesis. When the book dislocates from oracle, or a fresh liquidation map says mark is
walking into forced flow, the absorbing side moves from outside L1 to L1's own price and warehouses
the overshoot: the same clamp, reached from the other end. The desk becomes the best price on the
screen for whoever is being forced out, and the round trip against the book it read is still not
positive. That half pays twice a year. The half above is true in every block.

## The bound, against the book the quote read

One round trip, priced entirely off the same book the quote read: take the desk's price, close the
position at L1's own touch. On chain 999 at block 45 117 336, 2026-09-05T18:46:42Z, the canonical
parameters answered against a live L1 bid of 799 290 and ask of 799 300:

| the round trip | desk price | closed at | result |
|---|---|---|---|
| buy base from the desk, sell it into L1's bid | 800 899 | 799 290 | **−20.09 bps** |
| sell base to the desk, buy it back at L1's ask | 797 691 | 799 300 | **−20.13 bps** |

L1's own spread was 0.13 bps of that, and the exit has to cross it. `./script/probe999.sh` is those
prices from a shell with no key and nothing deployed; the Floor recomputes them every two seconds
and puts the better of the two directions — the arbitrageur's best case — in its header.

**The property is asserted, not described.** `test/Inarbitrable.t.sol` runs the same round trip
against `CoreQuote.extruction`, which is the code path the router settles through and not a display
helper. It never returns more than went in: either side, exact-in or exact-out, with or without a
curve ahead of the bound, over a fuzzed book, with the lean driven by the book or by a map oracle
that is lying, and with every rounding handed to the arbitrageur. The exit is priced at L1's touch
with no fee and no depth limit, which is a better exit than any that exists.

`test_lvr_theControlIsArbitrableAfterAMove_theDeskIsNot` is that bound in one test. Two
makers on 1inch's router, same pair, same inventory, both priced at the book they were shipped at.
The book then moves 12%, which is the 10 October 2025 move. The control is a constant product and
has not heard about it, so an arbitrageur now takes **1 352 bps** out of it in a single round trip.
The desk carries *the same constant product* — `XYCSwap` runs first in its own program and its
curve wants to pay that same stale price — and the bound cuts 794 715 284 units of quote back to
700 010 000, which is L1's own offer to the last unit. **Zero, not negative:** the desk is never a
better price than crossing L1, and never worse than useless.

**Where the desk still loses.** The reference price moves after a fill, which is inventory risk —
what the markout measures and what the cover leg is for. It inherits HyperCore's book, so if that
book is wrong against the rest of the world the desk is wrong with it. And a taker who is right
about the *next* move needs no instantaneous round trip to be right: the bound is against the book
in the call, on one instrument, at one instant.

