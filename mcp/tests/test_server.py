"""What must stay true about the answers, not about the plumbing.

The plumbing fails loudly. These are the four properties that would fail *quietly* and turn a
tool that states its limits into one that quietly invents: the bracket never becoming a midpoint,
the four kinds of absence never collapsing into one, provenance never going missing, and the
not-for-trading line never falling off a response.

    python3 -m unittest discover -s mcp/tests
"""

import json
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from coldcascade_mcp.server import Server, _tools  # noqa: E402
from coldcascade_mcp.store import CORPUS_SNAPSHOT, Book, Store, parse_time  # noqa: E402
from coldcascade_mcp.sync import _keeper  # noqa: E402


def book(t, blk, bid, ask):
    return Book(time=t, block=blk, bid=bid, ask=ask, mark=bid, oracle=bid,
                l1_block=1, poker="0xpoker", tx_hash="0x" + "aa" * 32)


class FakeStore(Store):
    """A store with a series we control: pokes at t=1000, 1060, then a hole, then 1600."""

    def __init__(self):
        self.corpus_override = Path("/nonexistent")
        self.corpus_path = Path("/nonexistent")
        self.corpus_kind = "explicit"
        self.artifact_path = Path("/nonexistent")
        self.books = [book(1000, 10, 100_000, 100_010),
                      book(1060, 20, 100_100, 100_110),
                      book(1600, 90, 101_000, 101_010)]
        self._btimes = [b.time for b in self.books]
        self._bblocks = sorted(range(len(self.books)), key=lambda i: self.books[i].block)
        self.fills, self.markouts, self.artifact = [], [], {}

    def load(self):
        pass


class Bracketing(unittest.TestCase):
    def setUp(self):
        self.s = FakeStore()

    def test_anInstantBetweenTwoPokesReturnsBothAndNoMidpoint(self):
        r = self.s.book_at(time=1030)
        self.assertEqual(r["status"], "bracketed")
        self.assertEqual(r["before"]["atUnix"], 1000)
        self.assertEqual(r["after"]["atUnix"], 1060)
        self.assertIs(r["interpolated"], False)
        # the one thing that must never appear: a fitted value between the two
        flat = json.dumps(r)
        self.assertNotIn("100050", flat, "a midpoint leaked into the response")

    def test_distancesAreReportedBothWays(self):
        r = self.s.book_at(time=1030)
        self.assertEqual(r["before"]["ageSeconds"], 30)
        self.assertEqual(r["after"]["aheadSeconds"], 30)

    def test_aPokeInTheRequestedBlockIsExact(self):
        r = self.s.book_at(block=20)
        self.assertEqual(r["status"], "exact")
        self.assertIsNone(r["after"])

    def test_aWideBracketCarriesAWarning(self):
        r = self.s.book_at(time=1300)          # inside the 540s hole
        self.assertEqual(r["status"], "bracketed")
        self.assertEqual(r["observationGapSeconds"], 540)
        self.assertIn("warning", r)

    def test_aNarrowBracketDoesNot(self):
        self.assertNotIn("warning", self.s.book_at(time=1030))


class AbsenceHasNames(unittest.TestCase):
    def setUp(self):
        self.s = FakeStore()

    def test_beforeTheFirstPokeIsBeforeSeriesAndSaysItIsUnrecoverable(self):
        r = self.s.book_at(time=500)
        self.assertEqual(r["status"], "beforeSeries")
        self.assertIsNone(r["before"])
        self.assertIn("never observed", r["explanation"])

    def test_afterTheLastPokeIsStaleNotBeforeSeries(self):
        r = self.s.book_at(time=9999)
        self.assertEqual(r["status"], "stale")
        self.assertIsNone(r["after"])

    def test_anEmptyArchiveSaysSoRatherThanReturningNothing(self):
        s = FakeStore(); s.books, s._btimes, s._bblocks = [], [], []
        self.assertEqual(s.book_at(time=1000)["status"], "noData")

    def test_theSeriesHoleIsReportedAsAHole(self):
        r = self.s.series(from_time=None, to_time=None)
        holes = r["cadence"]["holesOver180s"]
        self.assertEqual(len(holes), 1)
        self.assertEqual(holes[0]["gapSeconds"], 540)


class EveryResponseCarriesItsLimits(unittest.TestCase):
    """The rule that separates a tool from theatre: data, and what is wrong with it."""

    def setUp(self):
        self.server = Server()

    def test_everyToolAttachesProvenanceAndLimits(self):
        args = {
            "get_book_at_time": {"time": "2026-09-08T16:30:00Z"},
            "get_book_at_block": {"block": 45357494},
            "get_book_series": {"limit": 2},
            "get_fill": {"tx_hash": "0xfaf1b6c6"},
            "list_fills": {"limit": 2},
            "get_markouts": {"horizon": 60},
            "describe_coverage": {},
            # No token in the environment, so this returns notConfigured without touching the
            # network. That is the case under test: the tool must answer, not raise.
            "sync_stream": {},
        }
        self.assertEqual(set(args), {t["name"] for t in _tools()})
        cleared = {k: "" for k in ("SUBSTREAMS_API_TOKEN", "PINAX_JWT")}
        for name, a in args.items():
            with mock.patch.dict(os.environ, cleared):
                body = self.server.call_tool(name, a)
            self.assertIn("provenance", body, name)
            self.assertIn("notForTrading", body["limits"], name)
            self.assertEqual(body["provenance"]["chainId"], 999, name)

    def test_aBookAnswerSaysHowToReproduceAndHowToVerify(self):
        body = self.server.call_tool("get_book_at_block", {"block": 45357494})
        p = body["provenance"]
        self.assertIn("substreams run", p["reproduce"])
        self.assertIn("cast logs", p["verifyAgainstTheChain"])


class TheCorpusIsReachable(unittest.TestCase):
    """The finding this closes: on a clone the server must hold data and must say where from.

    Without these, `describe_coverage` on a fresh clone answers with zero observations and every
    book query answers `beforeSeries` — the stream is real and the server cannot reach it, which
    is indistinguishable from a static dataset with a provider's name on it.
    """

    def setUp(self):
        self.server = Server()

    def test_theCommittedSnapshotIsThereAndIsNotEmpty(self):
        self.assertTrue(CORPUS_SNAPSHOT.exists(), f"{CORPUS_SNAPSHOT} is not in the repository")
        s = Store(corpus=CORPUS_SNAPSHOT)
        self.assertGreater(len(s.books), 0, "the committed snapshot holds no Booked events")

    def test_coverageNamesWhichCorpusItRead(self):
        body = self.server.call_tool("describe_coverage", {})
        self.assertIn(body["corpus"]["kind"], ("live", "snapshot"))
        self.assertIsNotNone(body["corpus"]["lastBlock"])

    def test_withoutAKeyTheSyncSaysWhatIsMissingRatherThanFailingSilently(self):
        with mock.patch.dict(os.environ, {"SUBSTREAMS_API_TOKEN": "", "PINAX_JWT": ""}):
            body = self.server.call_tool("sync_stream", {})
        self.assertEqual(body["status"], "notConfigured")
        self.assertTrue(any("thegraph.market" in m for m in body["missing"]))
        # and it must still say what is being served in the meantime, with its last block
        self.assertIsNotNone(body["servingMeanwhile"]["lastBlock"])

    def test_theSyncReusesTheKeepersOwnStreamerRatherThanACopy(self):
        substreams = _keeper("substreams")
        self.assertTrue(hasattr(substreams, "cached_stream"))
        self.assertEqual(substreams.MODULE, "desk_events")
        self.assertIn("pinax", substreams.ENDPOINT)


class Protocol(unittest.TestCase):
    def setUp(self):
        self.server = Server()

    def test_initializeShipsTheInstructions(self):
        r = self.server.handle({"method": "initialize", "id": 1, "params": {}})
        self.assertEqual(r["protocolVersion"], "2024-11-05")
        self.assertIn("ignore the block tag", r["instructions"])
        for cap in ("tools", "resources", "prompts"):
            self.assertIn(cap, r["capabilities"])

    def test_aNotificationGetsNoReply(self):
        self.assertIsNone(self.server.handle({"method": "notifications/initialized"}))

    def test_anUnknownToolIsAResultNotAProtocolError(self):
        r = self.server.handle({"method": "tools/call", "id": 2,
                                "params": {"name": "nope", "arguments": {}}})
        self.assertTrue(r["isError"])

    def test_theSkillIsServedAsAResource(self):
        r = self.server.handle({"method": "resources/read", "id": 3,
                                "params": {"uri": "coldcascade://skill"}})
        text = r["contents"][0]["text"]
        self.assertIn("name: coldcascade-book-archive", text)
        self.assertIn("does not produce trading advice", text)

    def test_everyToolHasASchemaAndADescription(self):
        for t in _tools():
            self.assertTrue(t["description"].strip(), t["name"])
            self.assertEqual(t["inputSchema"]["type"], "object", t["name"])


class TimeParsing(unittest.TestCase):
    def test_isoWithoutOffsetIsUtcNotLocal(self):
        self.assertEqual(parse_time("1970-01-01T00:01:00"), 60)

    def test_zSuffixAndUnixAgree(self):
        self.assertEqual(parse_time("2026-09-08T16:30:00Z"), parse_time(1788885000))


if __name__ == "__main__":
    unittest.main()
