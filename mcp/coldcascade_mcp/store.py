"""What the server actually knows, and how sure it is of it.

Everything here comes from the Substreams stream, and it can arrive by either of two routes:

  * `keeper/.cache/desk_events.jsonl` — the live corpus, maintained by the keeper's cadence or by
    this server's own `sync_stream`. Local working state; not in the repository.
  * `results/desk-events.jsonl` — a committed snapshot of the same corpus, so a clone answers
    with no credentials and no network. Every response says which of the two it read and where
    that corpus stops, because a snapshot silently serving as live is the failure that would
    make this whole server a static dataset wearing a stream's label.

`results/markouts.json` is what the keeper derived from the corpus and is committed alongside.

No call in this module reaches the chain — the point of the book archive is that the chain
**cannot answer**, so an MCP server that fell back to an RPC would be answering a different
question. (`sync.py` makes exactly one node call, `eth_blockNumber`, to know where to stop
streaming. It never asks a node for a book.)

Two rules run through every function:

  * **Never interpolate.** If a poke did not land at the requested instant, the answer is the two
    pokes that bracket it, labelled with their distance, and a statement that no value between
    them was observed. A midpoint would look like data and be a guess.
  * **Absence has a name.** `beforeSeries`, `gap`, `noBook`, `pending` — the same vocabulary the
    artifact uses, so a caller that learns it once can read both.
"""

from __future__ import annotations

import bisect
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORPUS_LIVE = ROOT / "keeper" / ".cache" / "desk_events.jsonl"
CORPUS_SNAPSHOT = ROOT / "results" / "desk-events.jsonl"
ARTIFACT = ROOT / "results" / "markouts.json"

CHAIN_ID = 999
BOOK_CACHE = "0x24496697E43dE61af09561fb414cb909C1635533"
DESK_HOOKS = "0x84C1D720787F7D197dfc2890862E69c42aB0A363"
MARKOUT_LEDGER = "0xC938e0deD6A7a65B8f92Ca56E8688801eF0Ad0e9"
TOPIC_BOOKED = "0xd4d04ff23def09886e62b85b81ad08f3c4968122f84db18b16faaf72fc4cf305"
TOPIC_FILL = "0x999a9e88f019c1cef3020b109937c254b0474953cfe1b5dfbcc1d38ab5d00b77"
ENDPOINT = "hyperevm.substreams.pinax.network:443"
SPKG = "substreams/coldcascade-v0.1.0.spkg"
MODULE = "desk_events"

# Raw L1 prices are USD * 10^(6 - szDecimals). BTC has szDecimals 5, so one raw unit is 10 cents.
BTC_RAW_PER_USD = 10


def iso(ts: int) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value) -> int:
    """Unix seconds from a unix number or an ISO-8601 string. UTC unless an offset is given."""
    if isinstance(value, (int, float)):
        return int(value)
    s = str(value).strip().replace("Z", "+00:00")
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


@dataclass(frozen=True)
class Book:
    time: int
    block: int
    bid: int
    ask: int
    mark: int
    oracle: int
    l1_block: int
    poker: str
    tx_hash: str

    def out(self) -> dict:
        return {
            "atBlock": self.block,
            "atTime": iso(self.time),
            "atUnix": self.time,
            "bidRaw": self.bid, "askRaw": self.ask,
            "markRaw": self.mark, "oracleRaw": self.oracle,
            "bidUsd": self.bid / BTC_RAW_PER_USD,
            "askUsd": self.ask / BTC_RAW_PER_USD,
            "markUsd": self.mark / BTC_RAW_PER_USD,
            "oracleUsd": self.oracle / BTC_RAW_PER_USD,
            "midUsd": (self.bid + self.ask) / 2 / BTC_RAW_PER_USD,
            "spreadRaw": self.ask - self.bid,
            "l1Block": self.l1_block,
            "poker": self.poker,
            "txHash": self.tx_hash,
        }


class Store:
    def __init__(self, corpus: Path | None = None, artifact: Path = ARTIFACT):
        # `corpus=None` means "choose", and the choice is re-made on every load: a judge who runs
        # sync_stream creates the live cache mid-session, and the next answer should come from it.
        self.corpus_override, self.artifact_path = corpus, artifact
        self.corpus_path: Path = corpus or CORPUS_SNAPSHOT
        self.corpus_kind = "snapshot"
        self.books: list[Book] = []
        self.fills: list[dict] = []
        self.markouts: list[dict] = []
        self.artifact: dict = {}
        self.load()

    def _choose_corpus(self) -> None:
        """Live if the keeper (or `sync_stream`) has written one, otherwise the committed snapshot.

        Preferring live is not a preference for freshness in the abstract — it is that the live
        file is only ever the snapshot plus what has happened since, because `sync_stream` seeds
        it from the snapshot. So the live file is never behind, and never disagrees.
        """
        if self.corpus_override is not None:
            self.corpus_path, self.corpus_kind = self.corpus_override, "explicit"
        elif CORPUS_LIVE.exists() and CORPUS_LIVE.stat().st_size > 0:
            self.corpus_path, self.corpus_kind = CORPUS_LIVE, "live"
        else:
            self.corpus_path, self.corpus_kind = CORPUS_SNAPSHOT, "snapshot"

    def load(self) -> None:
        self._choose_corpus()
        books, fills, marks = [], [], []
        if self.corpus_path.exists():
            for line in self.corpus_path.read_text().splitlines():
                if not line.strip():
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                t, blk = int(d["timestamp"]), int(d["blockNumber"])
                for b in d.get("books", []):
                    books.append(Book(t, blk, int(b["bid"]), int(b["ask"]), int(b["mark"]),
                                      int(b["oracle"]), int(b["l1Block"]), b["poker"], b["txHash"]))
                for f in d.get("fills", []):
                    fills.append({**f, "block": blk, "time": t})
                for m in d.get("markouts", []):
                    marks.append({**m, "block": blk, "time": t})
        self.books = sorted(books, key=lambda b: (b.time, b.block))
        self.fills, self.markouts = fills, marks
        self._btimes = [b.time for b in self.books]
        self._bblocks = sorted(range(len(self.books)), key=lambda i: self.books[i].block)
        if self.artifact_path.exists():
            self.artifact = json.loads(self.artifact_path.read_text())

    # --- the archive -------------------------------------------------------------------------

    def _bracket_by(self, key, value, getter):
        """The last observation at or before `value`, and the first at or after it."""
        idx = bisect.bisect_left(key, value)
        before = None
        for i in range(idx - 1, -1, -1):
            before = getter(i)
            break
        if idx < len(key) and key[idx] == value:
            return getter(idx), getter(idx), True
        after = getter(idx) if idx < len(key) else None
        return before, after, False

    def book_at(self, *, block: int | None = None, time: int | None = None) -> dict:
        """The BBO HyperCore reported at a past moment — the query the chain cannot answer.

        `eth_call` against the HyperCore precompiles ignores the block tag and returns the
        *current* book, so this instant only exists because `BookCache.poke` wrote it into a log
        while it was current. What comes back is what was observed, bracketed, never fitted.
        """
        if not self.books:
            return {"status": "noData", "reason": "the corpus holds no Booked events"}

        if block is not None:
            ordered = [self.books[i] for i in self._bblocks]
            keys = [b.block for b in ordered]
            before, after, exact = self._bracket_by(keys, block, lambda i: ordered[i])
            asked = {"block": block}
        else:
            before, after, exact = self._bracket_by(self._btimes, time, lambda i: self.books[i])
            asked = {"time": iso(time), "unix": time}

        first, last = self.books[0], self.books[-1]
        if before is None:
            return {
                "query": asked, "status": "beforeSeries", "before": None,
                "after": after.out() if after else None,
                "seriesStart": {"atBlock": first.block, "atTime": iso(first.time),
                                "txHash": first.tx_hash},
                "explanation": (
                    "The requested moment predates the first poke. Before it there was no "
                    "`Booked` event on chain 999 at all, so this instant was never observed and "
                    "cannot be recovered from anywhere — the precompiles keep no history."
                ),
            }

        if exact:
            status, note = "exact", "A poke landed in the requested block."
        elif after is None:
            status = "stale"
            note = ("The series has not reached the requested moment yet; what is returned is the "
                    "most recent observation before it.")
        else:
            status = "bracketed"
            note = ("No poke landed at the requested moment. Both neighbours are returned; nothing "
                    "between them was observed and no value has been interpolated.")

        gap = (after.time - before.time) if (after and not exact) else 0
        out = {
            "query": asked,
            "status": status,
            "before": before.out(),
            "after": (after.out() if (after and not exact) else None),
            "interpolated": False,
            "explanation": note,
        }
        if before and time is not None:
            out["before"]["ageSeconds"] = time - before.time
        if after and time is not None and not exact:
            out["after"]["aheadSeconds"] = after.time - time
        if gap:
            out["observationGapSeconds"] = gap
            if gap > 180:
                out["warning"] = (
                    f"The two observations are {gap}s apart, wider than the one-minute cadence. "
                    "BTC can move materially inside that; treat the bracket as the bound, not as "
                    "a small uncertainty."
                )
        out["seriesCoverage"] = {
            "firstAtTime": iso(first.time), "firstAtBlock": first.block,
            "lastAtTime": iso(last.time), "lastAtBlock": last.block,
            "observations": len(self.books),
        }
        return out

    def series(self, *, from_time: int | None, to_time: int | None, limit: int = 200) -> dict:
        rows = self.books
        if from_time is not None:
            rows = [b for b in rows if b.time >= from_time]
        if to_time is not None:
            rows = [b for b in rows if b.time <= to_time]
        truncated = len(rows) > limit
        shown = rows[:limit]
        gaps = [(b.time - a.time) for a, b in zip(rows, rows[1:])]
        holes = [
            {"afterTime": iso(a.time), "beforeTime": iso(b.time), "gapSeconds": b.time - a.time}
            for a, b in zip(rows, rows[1:]) if b.time - a.time > 180
        ]
        return {
            "observations": [b.out() for b in shown],
            "returned": len(shown),
            "matched": len(rows),
            "truncated": truncated,
            "cadence": {
                "targetSeconds": 60,
                "medianGapSeconds": sorted(gaps)[len(gaps) // 2] if gaps else None,
                "maxGapSeconds": max(gaps) if gaps else None,
                "holesOver180s": holes,
            },
            "limits": {
                "note": (
                    "A hole is a stretch where no poke landed — usually a gas spike, since the "
                    "cadence thins when the base fee rises. Nothing fills a hole in later: an "
                    "instant inside one was never observed."
                ),
            },
        }

    # --- the desk's record -------------------------------------------------------------------

    def _enriched(self) -> list[dict]:
        """Fills as the keeper derived them: vsTouchBps, poolDevBps, quietBps, markout statuses."""
        return self.artifact.get("fills", [])

    def fill(self, tx_hash: str) -> dict:
        tx = tx_hash.lower()
        for f in self._enriched():
            if f["txHash"].lower().startswith(tx):
                return {"status": "found", "fill": self._explain_fill(f)}
        raw = [f for f in self.fills if f["txHash"].lower().startswith(tx)]
        if raw:
            return {
                "status": "notDerived",
                "fill": raw[0],
                "explanation": (
                    "The stream carries this fill but the keeper has not derived it yet, so "
                    "vsTouchBps, poolDevBps and the markouts are absent. Re-run "
                    "`python -m coldcascade markouts` and ask again."
                ),
            }
        return {
            "status": "notFound",
            "explanation": (
                f"No fill in the corpus has a transaction hash starting {tx_hash}. The corpus "
                f"covers blocks {self.artifact.get('source', {}).get('startBlock')} to "
                f"{self.artifact.get('source', {}).get('stopBlock')} on chain {CHAIN_ID}."
            ),
        }

    def _explain_fill(self, f: dict) -> dict:
        """The row, plus the one sentence that says which rule set this price."""
        out = dict(f)
        vs, dev, quiet = f.get("vsTouchBps"), f.get("poolDevBps"), f.get("quietBps")
        if vs is None:
            out["pricedBy"] = "unknown"
            out["pricedByExplanation"] = "The hook could not read the book for this fill."
        elif quiet is not None and abs(abs(vs) - quiet) < 0.5:
            out["pricedBy"] = "bound"
            out["pricedByExplanation"] = (
                f"The fill printed {vs:+.3f} bps against the L1 touch, which is this desk's own "
                f"quietBps of {quiet} to the basis point. In the quiet regime the taker receives "
                f"min(curve, bound); here the desk's constant-product curve wanted to deal inside "
                f"the band and the bound held it at the edge."
            )
        else:
            out["pricedBy"] = "curve"
            out["pricedByExplanation"] = (
                f"The fill printed {vs:+.3f} bps against the L1 touch, outside this desk's "
                f"quietBps of {quiet}, so the bound did not set it. The desk's own curve was "
                f"already the further-out side"
                + (f" — the pool sat {dev:+.1f} bps from L1 before the fill." if dev is not None
                   else ".")
            )
        return out

    def list_fills(self, *, desk=None, side=None, priced_by=None, since=None,
                   limit: int = 50) -> dict:
        rows = self._enriched()
        if desk:
            rows = [r for r in rows if r.get("deskName") == desk or r.get("desk", "").lower() == desk.lower()]
        if side in ("buysBase", "sellsBase"):
            want = side == "buysBase"
            rows = [r for r in rows if r.get("makerBuysBase") is want]
        if since is not None:
            rows = [r for r in rows if r.get("at", 0) >= since]
        rows = [self._explain_fill(r) for r in rows]
        if priced_by in ("bound", "curve"):
            rows = [r for r in rows if r["pricedBy"] == priced_by]
        rows.sort(key=lambda r: r.get("at", 0), reverse=True)
        return {
            "returned": len(rows[:limit]),
            "matched": len(rows),
            "fills": rows[:limit],
            "summary": self.artifact.get("summary", {}).get("bySide"),
        }

    def markouts_for(self, fill_id: str | None = None, horizon: int | None = None) -> dict:
        rows = []
        for f in self._enriched():
            if fill_id and not f["fillId"].lower().startswith(fill_id.lower()):
                continue
            for h, m in (f.get("markouts") or {}).items():
                if horizon is not None and int(h) != horizon:
                    continue
                rows.append({
                    "fillId": f["fillId"], "txHash": f["txHash"], "at": f.get("at"),
                    "horizonMinutes": int(h), **m,
                })
        posted = {(m["fillId"], int(m["horizonMinutes"])) for m in self.markouts}
        for r in rows:
            r["postedOnChain"] = (r["fillId"], r["horizonMinutes"]) in posted
        return {
            "returned": len(rows),
            "markouts": rows,
            "statusVocabulary": {
                "ok": "a book landed inside the horizon's tolerance; bps is the measurement",
                "pending": "the series has not reached the horizon yet; ask again later",
                "gap": "the series had a hole at the horizon; this markout will never exist",
                "beforeSeries": "the fill predates the first poke; there is no right-hand side to join to",
                "noBook": "the hook could not read this fill's own book, so there is no left-hand side",
            },
        }

    def coverage(self) -> dict:
        """What this server knows, what it does not, and what it must not be used for."""
        s = self.artifact.get("summary", {})
        src = self.artifact.get("source", {})
        first = self.books[0] if self.books else None
        last = self.books[-1] if self.books else None
        gaps = [(b.time - a.time) for a, b in zip(self.books, self.books[1:])]
        return {
            "chainId": CHAIN_ID,
            "source": src,
            "corpus": {
                "kind": self.corpus_kind,
                "path": str(self.corpus_path.relative_to(ROOT)) if self.corpus_path.exists() else None,
                "lastBlock": max((b.block for b in self.books), default=None),
                "note": (
                    "A committed snapshot of the stream, current to the block above. Call "
                    "sync_stream with a Substreams key to bring it to head from the provider."
                    if self.corpus_kind == "snapshot" else
                    "The live corpus, maintained by the keeper's cadence or by sync_stream on "
                    "this machine. It is the committed snapshot plus everything since."
                ),
            },
            "bookArchive": {
                "observations": len(self.books),
                "firstAtTime": iso(first.time) if first else None,
                "firstAtBlock": first.block if first else None,
                "lastAtTime": iso(last.time) if last else None,
                "lastAtBlock": last.block if last else None,
                "medianGapSeconds": sorted(gaps)[len(gaps) // 2] if gaps else None,
                "maxGapSeconds": max(gaps) if gaps else None,
                "perpIndex": 0,
                "instrument": "BTC perp BBO on Hyperliquid (HyperCore), as CoreQuote reads it",
            },
            "deskRecord": {
                "fills": s.get("fills"),
                "fillsWithCompleteHorizons": s.get("fillsWithCompleteHorizons"),
                "spanDays": s.get("spanDays"),
                "markoutsPostedOnChain": len(self.markouts),
            },
            "whatThisCannotAnswer": [
                "The book before the first poke. It was never written down and the precompiles "
                "keep no history, so no endpoint has it.",
                "Anything between two observations. The bracket is the bound; nothing is "
                "interpolated.",
                "Depth beyond the touch. BookCache stores four uint64 — bid, ask, mark, oracle — "
                "not an order book. Hyperliquid publishes its own L2 elsewhere.",
                "Whether a maker is unbacked: that lives in Aqua's Shipped event, which this "
                "package does not decode.",
                "A hedged desk's P&L. The perp leg is on HyperCore and in no EVM log here.",
            ],
            "notForTrading": (
                "This server returns observations and their limits. It does not produce trading "
                "advice, signals, or recommendations, and the markouts in it are not a "
                "performance claim: the demand on this desk is generated by a script in this "
                "repository, so they measure post-fill price drift and exist to show the keeper "
                "loop runs end to end."
            ),
        }


def provenance(kind: str, **kw) -> dict:
    """How to obtain the same answer without this server. Attached to every response."""
    base = {
        "chainId": CHAIN_ID,
        "provider": "The Graph Market for Substreams",
        "endpoint": ENDPOINT,
        "package": SPKG,
        "module": MODULE,
    }
    if kind == "book":
        blk = kw.get("block")
        base["contract"] = BOOK_CACHE
        base["event"] = "BookCache.Booked(uint32,uint64,uint64,uint64,uint64,uint64,address)"
        base["topic0"] = TOPIC_BOOKED
        if blk:
            base["reproduce"] = (
                f"substreams run -e {ENDPOINT} {SPKG} {MODULE} -s {blk} -t +1 -o json")
            base["verifyAgainstTheChain"] = (
                f"cast logs --from-block {blk} --to-block {blk} --address {BOOK_CACHE} "
                f"{TOPIC_BOOKED} --rpc-url $HYPEREVM_RPC_URL")
    elif kind == "fill":
        blk = kw.get("block")
        base["contract"] = DESK_HOOKS
        base["event"] = ("DeskHooks.Fill(bytes32,address,address,address,address,uint256,uint256,"
                         "uint64,uint64,uint64,uint64,uint128,uint128)")
        base["topic0"] = TOPIC_FILL
        if blk:
            base["reproduce"] = (
                f"substreams run -e {ENDPOINT} {SPKG} {MODULE} -s {blk} -t +1 -o json")
            base["verifyAgainstTheChain"] = f"cast receipt {kw.get('tx_hash','<txHash>')} --rpc-url $HYPEREVM_RPC_URL"
    elif kind == "markout":
        base["contract"] = MARKOUT_LEDGER
        base["event"] = "MarkoutLedger.Markout(bytes32,bytes32,uint8,int256,uint64)"
        base["derivedBy"] = "keeper/coldcascade/markouts.py"
    base["artifact"] = "https://coldcascade.vercel.app/results/markouts.json"
    return base
