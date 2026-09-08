"""The sign conventions, pinned.

Everything else in the keeper is plumbing that fails loudly. These two functions fail quietly:
a flipped sign still produces a plausible number in the right range, gets posted to the chain,
and reads as the desk being picked off when it was not. The `Markout` log is append-only and
`post` deliberately cannot restate, so a wrong sign is permanent.

Stdlib unittest, no fixtures, no network:  python3 -m unittest discover -s tests
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from coldcascade.markouts import (  # noqa: E402
    Fill, book_at, Book, fill_id, markout_bps, tolerance_s, vs_touch_bps,
)


def fill(maker_buys_base: bool, bid: int, ask: int, base: int = 1, quote: int = 1) -> Fill:
    return Fill(
        fill_id="0x00", order_hash="0x00", tx_hash="0x00", log_index=0, block=0, t=0,
        maker="0xdesk", taker="0xtaker", maker_buys_base=maker_buys_base,
        base_raw=base, quote_raw=quote, bid=bid, ask=ask, mark=(bid + ask) // 2,
        oracle=(bid + ask) // 2, book_ok=True,
    )


class MarkoutSign(unittest.TestCase):
    """A desk that bought base is long it: mid going up is the market moving its way."""

    def test_longBase_gainsWhenMidRises(self):
        f = fill(maker_buys_base=True, bid=100_000, ask=100_000)   # mid 100 000
        self.assertAlmostEqual(markout_bps(f, 100_100), 10.0, places=6)

    def test_longBase_losesWhenMidFalls(self):
        f = fill(maker_buys_base=True, bid=100_000, ask=100_000)
        self.assertAlmostEqual(markout_bps(f, 99_900), -10.0, places=6)

    def test_shortBase_gainsWhenMidFalls(self):
        f = fill(maker_buys_base=False, bid=100_000, ask=100_000)
        self.assertAlmostEqual(markout_bps(f, 99_900), 10.0, places=6)

    def test_shortBase_losesWhenMidRises(self):
        f = fill(maker_buys_base=False, bid=100_000, ask=100_000)
        self.assertAlmostEqual(markout_bps(f, 100_100), -10.0, places=6)

    def test_noMove_isExactlyZero(self):
        for side in (True, False):
            self.assertEqual(markout_bps(fill(side, 100_000, 100_002), 100_001.0), 0.0)


class VsTouchSign(unittest.TestCase):
    """A price statement, not a P&L: it says where the fill printed against the L1 touch.

    The desk deals at the bid when it buys base and at the ask when it sells, so `touch` picks
    the side and the sign then reads the same way for both: negative is below the touch."""

    def test_buyingBelowTheBid_isNegative(self):
        f = fill(maker_buys_base=True, bid=100_000, ask=100_010, base=1_000_000, quote=99_800_000)
        self.assertAlmostEqual(vs_touch_bps(f, 1, 1000), -20.0, places=6)

    def test_sellingAboveTheAsk_isPositive(self):
        f = fill(maker_buys_base=False, bid=100_000, ask=100_010, base=1_000_000, quote=100_210_020)
        self.assertAlmostEqual(vs_touch_bps(f, 1, 1000), 20.0, places=6)

    def test_theClampFill_reproducesMinusTwentyBps(self):
        """0xfaf1b6c6…dab20, block 45 195 770 on chain 999, off the receipt.

        1 000 000 raw base in, 795 396 020 raw quote out, L1 bid 796 990. This is the number the
        README and results/999_substreams_fill_decode.md both state, and it is `quietBps` on the
        desk's own frozen params."""
        f = fill(maker_buys_base=True, bid=796_990, ask=797_000,
                 base=1_000_000, quote=795_396_020)
        self.assertAlmostEqual(vs_touch_bps(f, 1, 1000), -20.0, places=3)


class Tolerance(unittest.TestCase):
    """A horizon is only that horizon if a book landed near it."""

    def test_isTheLargerOfTheFloorAndATenth(self):
        """Not "never more than a tenth" — for short horizons the floor is larger and wins, which
        is the honest bound: the series is one poke a minute and cannot do better."""
        for h in (1, 5, 15, 60, 240):
            self.assertEqual(tolerance_s(h), max(120, int(h * 60 * 0.10)))

    def test_theTenthBindsOnceTheHorizonIsLongEnough(self):
        self.assertEqual(tolerance_s(60), 360)      # a tenth of an hour
        self.assertEqual(tolerance_s(5), 120)       # the floor, which is 40% of five minutes

    def test_neverTighterThanTwoPokeIntervals(self):
        """The series is one poke a minute; asking for better than it can supply only drops fills."""
        for h in (1, 5, 15, 60):
            self.assertGreaterEqual(tolerance_s(h), 120)

    def test_bookAt_takesTheFirstOneInside(self):
        books = [Book(t=t, block=t, bid=100, ask=102, mark=101, oracle=101) for t in (1000, 1060, 1120)]
        self.assertEqual(book_at(books, 1050, 120).t, 1060)

    def test_bookAt_refusesOneOutside(self):
        books = [Book(t=t, block=t, bid=100, ask=102, mark=101, oracle=101) for t in (1000, 1400)]
        self.assertIsNone(book_at(books, 1050, 120))

    def test_bookAt_isNoneWhenTheSeriesHasNotReachedIt(self):
        books = [Book(t=1000, block=1, bid=100, ask=102, mark=101, oracle=101)]
        self.assertIsNone(book_at(books, 5000, 360))


class FillId(unittest.TestCase):
    """orderHash names the program, not the fill — every fill a desk makes carries the same one."""

    def test_carriesTheTransactionAndTheLogIndex(self):
        tx = "0x" + "ab" * 32
        self.assertEqual(fill_id(tx, 5), "0x" + "ab" * 28 + "00000005")

    def test_twoLogsInOneTransactionDiffer(self):
        tx = "0x" + "cd" * 32
        self.assertNotEqual(fill_id(tx, 0), fill_id(tx, 1))

    def test_isThirtyTwoBytes(self):
        self.assertEqual(len(bytes.fromhex(fill_id("0x" + "ef" * 32, 12)[2:])), 32)


if __name__ == "__main__":
    unittest.main()
