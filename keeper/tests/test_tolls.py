"""The counterfactual's two silent failures, pinned.

`tolls` answers "what would this trade have cost a different maker", and both halves of that
answer fail quietly rather than loudly. A flipped side turns a maker that was inside the venue
into one that was outside it and reports a toll where there was none — plausible, in range, and
wrong. A cadence that fires on every observation when it was asked for a fifteen-minute one
reports a stale maker's bleed as zero, which is the number that would flatter the desk most.

Neither is caught by anything downstream: the artifact just carries the number.

Stdlib unittest, no fixtures, no network:  python3 -m unittest discover -s tests
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from coldcascade.tolls import (  # noqa: E402
    Cadence, desk_toll, flat_curve_toll, oracle_pegged_toll, peg_at, peg_steps,
)


def obs(t: int, oracle: int, mark: int | None = None) -> dict:
    return {"t": t, "bid": oracle - 5, "ask": oracle + 5, "mark": mark or oracle, "oracle": oracle}


def fill(maker_buys_base: bool, bid: int, ask: int, *, at: int = 1_000, base: int = 10**8,
         quiet: int = 20, dev: float | None = 0.0, vs: float | None = 0.0) -> dict:
    """One fill of exactly one whole base unit, so a toll in USD is the gap in dollars."""
    return {
        "txHash": "0x00", "deskName": "demoDesk", "at": at, "bookOk": True,
        "makerBuysBase": maker_buys_base, "baseRaw": str(base),
        "bidRaw": bid, "askRaw": ask, "midRaw": (bid + ask) / 2,
        "touchRaw": bid if maker_buys_base else ask,
        "oracleRaw": (bid + ask) // 2, "markRaw": (bid + ask) // 2,
        "poolDevBps": dev, "quietBps": quiet, "vsTouchBps": vs,
    }


class RoundTripSide(unittest.TestCase):
    """A maker only pays when a searcher can close the round trip at L1's own touch."""

    def test_makerBuysBase_paysWhenItBidsAboveTheAsk(self):
        # Bids 100 100 while base can be bought back at 100 000: 10 bps, on one unit of base.
        f = fill(True, 99_990, 100_000, dev=None)
        t = flat_curve_toll({**f, "poolDevBps": 0.0, "oracleRaw": 100_100})
        self.assertAlmostEqual(t["bps"], 10.0, places=3)
        self.assertGreater(t["usd"], 0)

    def test_makerBuysBase_paysNothingWhenItBidsUnderTheAsk(self):
        t = flat_curve_toll({**fill(True, 99_990, 100_000), "poolDevBps": 0.0,
                             "oracleRaw": 99_900})
        self.assertLess(t["bps"], 0)
        self.assertEqual(t["usd"], 0)

    def test_makerSellsBase_paysWhenItAsksBelowTheBid(self):
        # Offers at 99 900 while base sells into the bid at 100 000: the mirror of the first case.
        t = flat_curve_toll({**fill(False, 100_000, 100_010), "poolDevBps": 0.0,
                             "oracleRaw": 99_900})
        self.assertAlmostEqual(t["bps"], 10.0, places=3)
        self.assertGreater(t["usd"], 0)

    def test_makerSellsBase_paysNothingWhenItAsksAboveTheBid(self):
        t = flat_curve_toll({**fill(False, 100_000, 100_010), "poolDevBps": 0.0,
                             "oracleRaw": 100_100})
        self.assertEqual(t["usd"], 0)


class DeskLine(unittest.TestCase):
    """The desk's own line is the receipt, so it has to come back out as the receipt went in."""

    def test_aFillInsideTheTouch_paysNothing(self):
        # Bought base 20 bps under the bid — the band doing its job — so nothing to take.
        t = desk_toll(fill(True, 100_000, 100_010, vs=-20.0))
        self.assertEqual(t["usd"], 0)
        self.assertAlmostEqual(t["pxRaw"], 100_000 * (1 - 20 / 10_000), places=2)

    def test_aFillOutsideTheTouch_pays(self):
        t = desk_toll(fill(True, 100_000, 100_010, vs=+50.0))
        self.assertGreater(t["usd"], 0)

    def test_aFillWithNoBook_isNotPricedAtZero(self):
        t = desk_toll({**fill(True, 0, 0, vs=None), "bookOk": False})
        self.assertEqual(t["status"], "noBook")
        self.assertIsNone(t["usd"])


class CadenceFires(unittest.TestCase):
    """When the peg moves. Every number in the artifact is a function of this."""

    SERIES = [obs(0, 100_000), obs(60, 100_050), obs(120, 100_400), obs(180, 100_410)]

    def test_heartbeatAlone_movesItOnTheClock(self):
        times, pegs = peg_steps(self.SERIES, Cadence("t", 0.0, 120))
        self.assertEqual(times, [0, 120])
        self.assertEqual(pegs, [100_000, 100_400])

    def test_zeroDeviation_doesNotMeanEveryObservation(self):
        """`>= 0` is true of every move, which would make the deviation dial fire always."""
        times, _ = peg_steps(self.SERIES, Cadence("t", 0.0, 10_000))
        self.assertEqual(times, [0])

    def test_deviation_movesItOffTheClock(self):
        # 40 bps at t=120 clears a 25 bps threshold; the 5 bps at t=60 does not.
        times, _ = peg_steps(self.SERIES, Cadence("t", 25.0, 10_000))
        self.assertEqual(times, [0, 120])

    def test_reference_choosesTheWord(self):
        series = [obs(0, 100_000, mark=99_000)]
        _, on_oracle = peg_steps(series, Cadence("t", 0.0, 60, "oracle"))
        _, on_mark = peg_steps(series, Cadence("t", 0.0, 60, "mark"))
        self.assertEqual((on_oracle[0], on_mark[0]), (100_000, 99_000))

    def test_pegAt_isTheLastRefreshAtOrBeforeTheFill(self):
        times, pegs = peg_steps(self.SERIES, Cadence("t", 0.0, 120))
        self.assertEqual(peg_at(times, pegs, 119), (100_000, 0))
        self.assertEqual(peg_at(times, pegs, 120), (100_400, 120))
        self.assertIsNone(peg_at(times, pegs, -1))


class PeggedMaker(unittest.TestCase):
    """The comparator itself: a price from the past, a band around it, and what that costs."""

    SERIES = [obs(0, 100_000), obs(600, 100_000)]

    def pegged(self, f, band=None, series=None, start=0):
        series = series or self.SERIES
        times, pegs = peg_steps(series, Cadence("t", 0.0, 60))
        seen = sorted(o["t"] for o in series)
        return oracle_pegged_toll(
            f, times, pegs,
            lambda t: max((s for s in seen if s <= t), default=None),
            start, band,
        )

    def test_aStalePeg_paysWhenTheBookHasMovedPastTheBand(self):
        # Peg 100 000, band 20 bps, so it bids 99 800 while the market has fallen to a 99 000 ask.
        t = self.pegged(fill(True, 98_990, 99_000, at=60))
        self.assertGreater(t["usd"], 0)
        self.assertEqual(t["pegRaw"], 100_000)
        self.assertEqual(t["pegAgeSeconds"], 60)

    def test_aFreshPeg_paysNothing(self):
        t = self.pegged(fill(True, 99_995, 100_005, at=60))
        self.assertEqual(t["usd"], 0)

    def test_aWiderBand_neverPaysMore(self):
        f = fill(True, 99_800, 99_810, at=60)
        wide = self.pegged(f, band=50)
        tight = self.pegged(f, band=0)
        self.assertLessEqual(wide["usd"], tight["usd"])

    def test_beforeTheSeries_isNotZero(self):
        t = self.pegged(fill(True, 99_000, 99_010, at=-30), start=0)
        self.assertEqual(t["status"], "beforeSeries")
        self.assertIsNone(t["usd"])

    def test_aHoleInTheSeries_isNotZeroEither(self):
        # The fill lands 600 s after the last observation. The maker would have refreshed off an
        # oracle nobody wrote down, so the honest answer is that this fill has no peg.
        t = self.pegged(fill(True, 99_000, 99_010, at=1_200))
        self.assertEqual(t["status"], "gap")
        self.assertIsNone(t["usd"])


if __name__ == "__main__":
    unittest.main()
