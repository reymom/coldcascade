"""Read Graph, decide, write chain.

Fills come from the Substreams stream (`DeskHooks.Fill`, carrying the book the quote read while
pricing that very swap); the later book comes from the same stream (`BookCache.Booked`). The
markout of a fill at horizon h is the signed move of L1 mid from the fill to h minutes later,
from the maker's side, in basis points. It is posted to `MarkoutLedger`, whose `Markout` log the
same stream then picks up — which is what closes the loop, and what stops the keeper from ever
restating a number it has already published.

What a markout here is and is not.

  * It is adverse selection: did the market move against the side the desk ended up holding.
    A negative markout is the desk having been picked off. That is the quantity the LVR
    literature is about, and it is the one this repository set out to drive to zero.
  * It is not a yield, and it is not the desk's P&L. It ignores the spread captured at the touch
    (reported separately, per fill, as `vsTouchBps`) and it ignores the perp leg entirely. A
    hedged desk marks spot and short at a common price and the move cancels; its P&L is a third
    measurement and this file does not compute it.
  * It is a handful of events. Say the count before the number, every time.
"""

from __future__ import annotations

import json
import statistics
import time
from dataclasses import dataclass, field
from pathlib import Path

from . import substreams
from .chain import ChainError, Deployment, desk_params

HORIZONS_MIN = (5, 15, 60)

# The book series is written one poke a minute. A horizon is honest only if a book landed close
# to it: the first Booked at or after t+h, and no later than this. Without the bound, a fill from
# before the cadence started would be "marked out at 5 minutes" against a book five hours later,
# which is not a five-minute markout — it is an arbitrary one wearing the label.
TOLERANCE_S = 180


@dataclass(frozen=True)
class Fill:
    fill_id: str
    order_hash: str
    tx_hash: str
    log_index: int
    block: int
    t: int
    maker: str
    taker: str
    maker_buys_base: bool
    base_raw: int
    quote_raw: int
    bid: int
    ask: int
    mark: int
    oracle: int
    book_ok: bool

    @property
    def mid(self) -> float:
        return (self.bid + self.ask) / 2

    @property
    def touch(self) -> int:
        """The side the desk actually dealt at: it buys base at the bid and sells at the ask."""
        return self.bid if self.maker_buys_base else self.ask


@dataclass(frozen=True)
class Book:
    t: int
    block: int
    bid: int
    ask: int
    mark: int
    oracle: int

    @property
    def mid(self) -> float:
        return (self.bid + self.ask) / 2


@dataclass
class Corpus:
    fills: list[Fill] = field(default_factory=list)
    books: list[Book] = field(default_factory=list)
    posted: set[tuple[str, int]] = field(default_factory=set)
    stop_block: int = 0


def fill_id(tx_hash: str, log_index: int) -> str:
    """A bytes32 that names one fill, and shows its provenance.

    The `orderHash` in a Fill is Aqua's strategy hash — it names the *program*, and every fill a
    desk makes carries the same one, so it cannot be the key. This is the transaction hash with
    its last four bytes replaced by the log index: unique, deterministic, and a reader who sees
    it in a `Markout` log can recognise the transaction it came from without a lookup table.
    """
    return "0x" + bytes.fromhex(tx_hash[2:])[:28].hex() + log_index.to_bytes(4, "big").hex()


def collect(dep: Deployment, start_block: int, stop_block: int) -> Corpus:
    """One pass of the stream: every fill, every book, and every markout already posted."""
    c = Corpus(stop_block=stop_block)
    base_of: dict[str, str] = {}

    for blk in substreams.stream(start_block, stop_block):
        t = int(blk["timestamp"])
        block = int(blk["blockNumber"])

        for f in blk.get("fills", []):
            maker = f["maker"].lower()
            if maker not in base_of:
                try:
                    base_of[maker] = desk_params(dep, maker)["base"].lower()
                except ChainError:
                    # A desk that has since closed still has its fills on the chain. Without its
                    # params there is no way to know which leg was base, so the side is unknown
                    # and the fill is not markoutable. Skipped loudly, not guessed.
                    print(f"  ! {f['txHash'][:12]}: cannot read params() of maker {maker}; skipped")
                    base_of[maker] = ""
            base = base_of[maker]
            if not base:
                continue
            # tokenIn/tokenOut are the taker's legs as the router sees them. The taker putting
            # base in is the desk taking base on.
            maker_buys_base = f["tokenIn"].lower() == base
            amount_in, amount_out = int(f["amountIn"]), int(f["amountOut"])
            c.fills.append(
                Fill(
                    fill_id=fill_id(f["txHash"], int(f["logIndex"])),
                    order_hash=f["orderHash"],
                    tx_hash=f["txHash"],
                    log_index=int(f["logIndex"]),
                    block=block,
                    t=t,
                    maker=maker,
                    taker=f["taker"],
                    maker_buys_base=maker_buys_base,
                    base_raw=amount_in if maker_buys_base else amount_out,
                    quote_raw=amount_out if maker_buys_base else amount_in,
                    bid=int(f["bid"]),
                    ask=int(f["ask"]),
                    mark=int(f["mark"]),
                    oracle=int(f["oracle"]),
                    book_ok=bool(f["bookOk"]),
                )
            )

        for b in blk.get("books", []):
            c.books.append(
                Book(t=t, block=block, bid=int(b["bid"]), ask=int(b["ask"]),
                     mark=int(b["mark"]), oracle=int(b["oracle"]))
            )

        for m in blk.get("markouts", []):
            c.posted.add((m["fillId"], int(m["horizonMinutes"])))

    c.fills.sort(key=lambda f: (f.t, f.block, f.log_index))
    c.books.sort(key=lambda b: (b.t, b.block))
    return c


def book_at(books: list[Book], target_t: int, tolerance_s: int = TOLERANCE_S) -> Book | None:
    """The first book at or after `target_t`, if one landed inside the tolerance."""
    for b in books:                       # sorted; the corpus is small enough that this is honest
        if b.t >= target_t:
            return b if b.t - target_t <= tolerance_s else None
    return None


def markout_bps(fill: Fill, mid_later: float) -> float:
    """Signed move of mid from the maker's side, in bps.

    The desk that bought base is long it and gains when mid rises; the desk that sold base is
    short and gains when mid falls. One sign, and it is the whole content of the number: a
    markout that can only be positive is not a measurement.
    """
    sign = 1.0 if fill.maker_buys_base else -1.0
    return sign * (mid_later - fill.mid) / fill.mid * 10_000.0


def vs_touch_bps(fill: Fill, px_num: int, px_den: int) -> float:
    """Where the fill printed against the L1 touch, in bps. Not a P&L — a price statement.

    Negative means the desk bought below the bid; positive means it sold above the ask. Either
    way it is the clamp doing its job, and its magnitude is the maker's own `quietBps` when
    nothing is happening. `amountQuote = amountBase * rawPx * pxNum / pxDen`, so the raw price
    this fill printed at is the ratio put back through that scale.
    """
    exec_px = (fill.quote_raw / fill.base_raw) * px_den / px_num
    return (exec_px - fill.touch) / fill.touch * 10_000.0


# --- the loop ---------------------------------------------------------------------------------

def _stats(xs: list[float]) -> dict:
    if not xs:
        return {"n": 0, "meanBps": None, "medianBps": None, "worstBps": None, "bestBps": None}
    return {
        "n": len(xs),
        "meanBps": round(statistics.fmean(xs), 3),
        "medianBps": round(statistics.median(xs), 3),
        "worstBps": round(min(xs), 3),
        "bestBps": round(max(xs), 3),
    }


def run(
    dep: Deployment,
    account: str,
    password_file: str | None = None,
    start_block: int | None = None,
    stop_block: int | None = None,
    out: Path | None = None,
    dry_run: bool = True,
    limit: int | None = None,
) -> dict:
    """One pass: stream, join, post what is new, write the artifact the page reads."""
    from .chain import rpc, send

    start_block = start_block or dep.deployed_at_block
    stop_block = stop_block or int(rpc(dep, "eth_blockNumber", []), 16)
    out = out or (Path(__file__).resolve().parents[2] / "results" / "markouts.json")
    name_of = {v.lower(): k for k, v in dep.desks.items()}

    print(f"streaming {stop_block - start_block} blocks, {start_block} -> {stop_block}")
    c = collect(dep, start_block, stop_block)
    print(f"  {len(c.fills)} fills · {len(c.books)} books · {len(c.posted)} markouts already posted")

    scale: dict[str, tuple[int, int]] = {}
    rows, to_post = [], []

    for f in c.fills:
        if f.maker not in scale:
            p = desk_params(dep, f.maker)
            scale[f.maker] = (p["pxNum"], p["pxDen"])
        px_num, px_den = scale[f.maker]

        row = {
            "fillId": f.fill_id,
            "txHash": f.tx_hash,
            "logIndex": f.log_index,
            "block": f.block,
            "at": f.t,
            "desk": f.maker,
            "deskName": name_of.get(f.maker, "unknown"),
            "taker": f.taker,
            "orderHash": f.order_hash,
            "makerBuysBase": f.maker_buys_base,
            "baseRaw": str(f.base_raw),
            "quoteRaw": str(f.quote_raw),
            "bookOk": f.book_ok,
            "bidRaw": f.bid,
            "askRaw": f.ask,
            "midRaw": f.mid,
            "touchRaw": f.touch,
            "vsTouchBps": None,
            "markouts": {},
        }
        # A fill whose book could not be read arrives as four zeros. The hook is fail-soft by
        # design — nothing after the transfer is allowed to fail the transfer — so this is a
        # fill to skip, not a fill that happened at a price of zero.
        if f.book_ok and f.base_raw:
            row["vsTouchBps"] = round(vs_touch_bps(f, px_num, px_den), 3)

        for h in HORIZONS_MIN:
            b = book_at(c.books, f.t + h * 60) if f.book_ok else None
            if b is None:
                row["markouts"][str(h)] = None
                continue
            bps = markout_bps(f, b.mid)
            row["markouts"][str(h)] = {
                "bps": round(bps, 3),
                "midRaw": b.mid,
                "bookAt": b.t,
                "bookBlock": b.block,
                "lagSeconds": b.t - (f.t + h * 60),
            }
            if (f.fill_id, h) not in c.posted:
                to_post.append((f, h, int(round(bps))))

        rows.append(row)

    complete = sum(1 for r in rows if all(r["markouts"].get(str(h)) for h in HORIZONS_MIN))
    gaps = [b.t - a.t for a, b in zip(c.books, c.books[1:])]
    ts = [f.t for f in c.fills]

    doc = {
        "generatedAt": int(time.time()),
        "chainId": dep.chain_id,
        "source": {
            "provider": "The Graph Market for Substreams",
            "endpoint": substreams.ENDPOINT,
            "package": substreams.SPKG.name,
            "module": substreams.MODULE,
            "startBlock": start_block,
            "stopBlock": stop_block,
        },
        "horizonsMinutes": list(HORIZONS_MIN),
        "toleranceSeconds": TOLERANCE_S,
        "books": {
            "count": len(c.books),
            "firstAt": c.books[0].t if c.books else None,
            "lastAt": c.books[-1].t if c.books else None,
            "medianGapSeconds": round(statistics.median(gaps), 1) if gaps else None,
        },
        "summary": {
            "fills": len(rows),
            "fillsWithCompleteHorizons": complete,
            "firstFillAt": min(ts) if ts else None,
            "lastFillAt": max(ts) if ts else None,
            "spanDays": round((max(ts) - min(ts)) / 86400, 2) if len(ts) > 1 else 0.0,
            "byHorizon": {
                str(h): _stats([r["markouts"][str(h)]["bps"] for r in rows if r["markouts"].get(str(h))])
                for h in HORIZONS_MIN
            },
            "vsTouch": _stats([r["vsTouchBps"] for r in rows if r["vsTouchBps"] is not None]),
        },
        "fills": rows,
        "postedThisRun": [],
    }

    if limit is not None:
        to_post = to_post[:limit]
    print(f"  {complete}/{len(rows)} fills carry a complete 5/15/60 · {len(to_post)} markouts to post")

    for f, h, bps in to_post:
        print(f"  post {f.fill_id[:14]}… h={h:>2}m bps={bps:>5}")
        tx = send(
            dep, dep.markout_ledger,
            "post(bytes32,bytes32,uint8,int256)",
            [f.order_hash, f.fill_id, str(h), str(bps)],
            account=account, password_file=password_file, dry_run=dry_run,
        )
        if tx:
            doc["postedThisRun"].append(
                {"fillId": f.fill_id, "horizonMinutes": h, "bps": bps, "txHash": tx}
            )

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, indent=2) + "\n")
    print(f"  wrote {out}")
    return doc
