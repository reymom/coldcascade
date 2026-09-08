"""Read Graph, decide, write chain.

Fills come from the Substreams stream (`DeskHooks.Fill`, carrying the book the quote read while
pricing that very swap); the later book comes from the same stream (`BookCache.Booked`). The
markout of a fill at horizon h is the signed move of L1 mid from the fill to h minutes later,
from the maker's side, in basis points. It is posted to `MarkoutLedger`, whose `Markout` log the
same stream then picks up — which is what closes the loop, and what stops the keeper from ever
restating a number it has already published.

What a markout here is, and what it is emphatically not.

**The demand on this desk is scripted.** `script/demo-cadence.sh` sends a take every twenty
minutes and picks its side and size from the pool's own drift and the desk's inventory. Nobody is
trading against this desk because they thought the price was wrong. So the number below is post-fill
drift of BTC, sampled at hours a cron chose, and calling it adverse selection would be describing a
measurement nobody made: adverse selection is a claim about *who* traded and *why*, and here the
answer to both is us.

  * It is a signed price move over a fixed horizon, and that is all. Negative means L1 mid moved
    against the side the desk ended up holding. With flow the desk generated itself, that is a
    fact about BTC in those minutes, not a fact about the desk.
  * It is not a yield and it is not the desk's P&L. It ignores the spread captured at the touch
    (reported separately, per fill, as `vsTouchBps`) and it ignores the perp leg entirely. A
    hedged desk marks spot and short at a common price and the move cancels; its P&L is a third
    measurement and this file does not compute it.
  * **What it does demonstrate is this loop.** Read the stream, join a fill to a later book,
    decide a number, write it to the chain, and read the decision back off the same stream on the
    next pass. Every step of that is exercised by every markout posted, and that is the reason to
    compute them.

The argument about the mechanism does not rest here. It rests on `vs_touch_bps`, because a fill
printing at its maker's `quietBps` to the basis point is a property of the program — checkable on
one transaction against one receipt — rather than a statistic that needs a sample to mean anything.
"""

from __future__ import annotations

import json
import statistics
import time
from dataclasses import dataclass, field
from pathlib import Path

from . import substreams
from .chain import ChainError, Deployment, desk_params, token_balance_at

HORIZONS_MIN = (5, 15, 60)

# The book series is written one poke a minute. A horizon is honest only if a book landed close to
# it: the first Booked at or after t+h, and no later than the tolerance. Without the bound, a fill
# from before the cadence started would be "marked out at 5 minutes" against a book five hours
# later, which is not a five-minute markout — it is an arbitrary one wearing the label.
#
# The tolerance scales with the horizon, because a flat one does not mean the same thing at both
# ends: three minutes late on a five-minute markout is a 60% error and on a sixty-minute markout
# it is 5%. So: never more than a tenth of the horizon, and never tighter than two poke intervals,
# since demanding better than the series can supply only throws away fills.
TOLERANCE_FLOOR_S = 120
TOLERANCE_FRACTION = 0.10


def tolerance_s(horizon_min: int) -> int:
    return max(TOLERANCE_FLOOR_S, int(horizon_min * 60 * TOLERANCE_FRACTION))


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

    for blk in substreams.cached_stream(start_block, stop_block):
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


def book_at(books: list[Book], target_t: int, tolerance: int) -> tuple[Book | None, str, int | None]:
    """The first book at or after `target_t`, and — when there isn't one — why not.

    Two different absences, and a page that shows them the same way is lying by omission. The
    series not having reached `target_t` yet resolves itself in a few minutes. A hole in the
    series at `target_t` never resolves: that markout does not exist and will not later.
    Returns (book, status, lag), status in {"ok", "pending", "gap"}.
    """
    for b in books:                       # sorted; the corpus is small enough that this is honest
        if b.t >= target_t:
            lag = b.t - target_t
            return (b, "ok", lag) if lag <= tolerance else (None, "gap", lag)
    return None, "pending", None


def markout_bps(fill: Fill, mid_later: float) -> float:
    """Signed move of mid from the maker's side, in bps.

    The desk that bought base is long it and gains when mid rises; the desk that sold base is
    short and gains when mid falls. One sign, and it is the whole content of the number: a
    markout that can only be positive is not a measurement. What the sign does *not* carry is an
    attribution — see the module docstring on why scripted demand makes this a price move rather
    than an adverse-selection number.
    """
    sign = 1.0 if fill.maker_buys_base else -1.0
    return sign * (mid_later - fill.mid) / fill.mid * 10_000.0


POOL_DEV_CACHE = Path(__file__).resolve().parents[1] / ".cache" / "pool-dev.json"


def pool_dev_bps(dep: Deployment, fill: Fill, base: str, quote: str,
                 px_num: int, px_den: int) -> float | None:
    """Where the desk's own constant-product curve sat against L1 *before* this fill, in bps.

    This is the variable that decides which of the two regimes a fill lands in, and it is not in
    the Fill event. `out = min(curve, bound)`: when the pool prices base above L1 the curve is
    already the dearer side of a sale and the bound stands aside, while a purchase at that pool
    would pay over L1 and gets cut back to the band. Below L1 the two swap round. So a fill at
    ±quietBps and a fill at +156 are not two behaviours, they are one rule seen from two sides,
    and `poolDevBps` is the side.

    Reserves come from the archive endpoint at `block - 1`; L1 comes from the fill's own oracle
    word, which is the same number `CoreQuote` priced against and is already in the log. The
    result is immutable once computed, so it is cached by transaction hash.
    """
    if not fill.book_ok or not fill.oracle:
        return None
    try:
        b = token_balance_at(dep, base, fill.maker, fill.block - 1)
        q = token_balance_at(dep, quote, fill.maker, fill.block - 1)
    except Exception:
        # A third-party archive is not something to fail a run over. The markout does not need it.
        return None
    if not b or not q:
        return None
    l1 = fill.oracle * px_num / px_den
    return (q / b / l1 - 1) * 10_000.0


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
    """min and max, not worst and best. For a markout the minimum *is* the worst, but the same
    helper describes `vsTouch`, where a large positive number is the curve winning rather than
    the desk doing well, and a label that picks a side there would be editorialising."""
    if not xs:
        return {"n": 0, "meanBps": None, "medianBps": None, "minBps": None, "maxBps": None}
    return {
        "n": len(xs),
        "meanBps": round(statistics.fmean(xs), 3),
        "medianBps": round(statistics.median(xs), 3),
        "minBps": round(min(xs), 3),
        "maxBps": round(max(xs), 3),
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
    tokens: dict[str, tuple[str, str]] = {}
    quiet: dict[str, int] = {}
    dev_cache: dict[str, float | None] = {}
    if POOL_DEV_CACHE.exists():
        try:
            dev_cache = json.loads(POOL_DEV_CACHE.read_text())
        except json.JSONDecodeError:
            dev_cache = {}
    rows, to_post = [], []
    # When the book series begins. Before it, `BookCache.poke` had never been called on mainnet:
    # pokedAt(0) was 0 and there was no Booked event on chain 999 at all.
    series_start = c.books[0].t if c.books else None

    for f in c.fills:
        if f.maker not in scale:
            p = desk_params(dep, f.maker)
            scale[f.maker] = (p["pxNum"], p["pxDen"])
            tokens[f.maker] = (p["base"], p["quote"])
            quiet[f.maker] = p["quietBps"]
        px_num, px_den = scale[f.maker]

        # Immutable once computed — it is a past block's state — so it is asked for once.
        if f.tx_hash not in dev_cache:
            base_tok, quote_tok = tokens[f.maker]
            d = pool_dev_bps(dep, f, base_tok, quote_tok, px_num, px_den)
            dev_cache[f.tx_hash] = round(d, 3) if d is not None else None

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
            "poolDevBps": dev_cache.get(f.tx_hash),
            "quietBps": quiet[f.maker],
            "vsTouchBps": None,
            "markouts": {},
        }
        # A fill whose book could not be read arrives as four zeros. The hook is fail-soft by
        # design — nothing after the transfer is allowed to fail the transfer — so this is a
        # fill to skip, not a fill that happened at a price of zero.
        if f.book_ok and f.base_raw:
            row["vsTouchBps"] = round(vs_touch_bps(f, px_num, px_den), 3)

        for h in HORIZONS_MIN:
            tol = tolerance_s(h)
            if not f.book_ok:
                # The hook is fail-soft: a book it could not read arrives as four zeros. There is
                # no left-hand side, so there is no markout, and there never will be for this fill.
                row["markouts"][str(h)] = {"bps": None, "status": "noBook", "toleranceSeconds": tol}
                continue
            b, status, lag = book_at(c.books, f.t + h * 60, tol)
            # A hole in a running series and a fill that predates the series are both "no book
            # here", and calling them the same thing would be the page's most misleading number.
            # The eight fills older than the first poke can never acquire a markout; a gap in a
            # live series is an operational fact about one afternoon.
            if b is None and status == "gap" and series_start is not None and f.t < series_start:
                status = "beforeSeries"
            if b is None:
                row["markouts"][str(h)] = {
                    "bps": None, "status": status, "toleranceSeconds": tol,
                    "nearestLagSeconds": lag,
                }
                continue
            bps = markout_bps(f, b.mid)
            row["markouts"][str(h)] = {
                "bps": round(bps, 3),
                "status": "ok",
                "midRaw": b.mid,
                "bookAt": b.t,
                "bookBlock": b.block,
                "lagSeconds": lag,
                "toleranceSeconds": tol,
            }
            if (f.fill_id, h) not in c.posted:
                # `post` takes int256 bps and the ledger's unit is a basis point, so the number
                # that reaches the chain is rounded. The unrounded one stays in this artifact:
                # the chain is where the decision is recorded, not where the precision lives.
                to_post.append((f, h, int(round(bps))))

        rows.append(row)

    def bps_of(r, h):
        m = r["markouts"].get(str(h))
        return m["bps"] if m and m.get("bps") is not None else None

    complete = sum(1 for r in rows if all(bps_of(r, h) is not None for h in HORIZONS_MIN))

    def subset_stats(rs: list[dict]) -> dict:
        # "At the band" means the bound is what set this price: the fill printed at the desk's own
        # quietBps, read off its frozen params rather than assumed to be 20.
        clamped = [
            r for r in rs
            if r["vsTouchBps"] is not None and abs(abs(r["vsTouchBps"]) - r["quietBps"]) < 0.5
        ]
        return {
            "fills": len(rs),
            "atTheBand": len(clamped),
            "vsTouch": _stats([r["vsTouchBps"] for r in rs if r["vsTouchBps"] is not None]),
            "poolDev": _stats([r["poolDevBps"] for r in rs if r.get("poolDevBps") is not None]),
            "byHorizon": {
                str(h): _stats([bps_of(r, h) for r in rs if bps_of(r, h) is not None])
                for h in HORIZONS_MIN
            },
        }

    def side_stats(buys: bool) -> dict:
        return subset_stats([r for r in rows if r["makerBuysBase"] is buys])

    def horizon_stats(h: int) -> dict:
        st = _stats([bps_of(r, h) for r in rows if bps_of(r, h) is not None])
        for label in ("pending", "gap", "noBook", "beforeSeries"):
            st[label] = sum(1 for r in rows if (r["markouts"].get(str(h)) or {}).get("status") == label)
        return st
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
            # Where the *flow* came from, stated next to where the data came from, because a
            # reader who has one and not the other will draw the wrong conclusion from the
            # markouts. Every fill here was sent by this repository.
            "demand": {
                "scripted": True,
                "generator": "script/demo-cadence.sh",
                "intervalMinutes": 20,
                "note": (
                    "Every fill on this desk was sent by this repository, on a schedule, with "
                    "side and size chosen from the pool's drift and the desk's inventory. The "
                    "markouts are therefore post-fill price drift over fixed horizons, not a "
                    "measurement of adverse selection and not an edge claim. They are here "
                    "because they exercise the keeper loop end to end: stream, join, decide, "
                    "write to chain, read the decision back. The claim about the mechanism is "
                    "vsTouchBps, which is a property of the program checkable on one fill."
                ),
            },
        },
        "horizonsMinutes": list(HORIZONS_MIN),
        "toleranceSeconds": {str(h): tolerance_s(h) for h in HORIZONS_MIN},
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
            "byHorizon": {str(h): horizon_stats(h) for h in HORIZONS_MIN},
            "vsTouch": _stats([r["vsTouchBps"] for r in rows if r["vsTouchBps"] is not None]),
            # Split by side, because the two sides are not one population. `out = min(curve,
            # bound)` binds on whichever side the pool is currently the cheaper one, so pooling
            # them averages the bound's own signature together with the curve's and reports a
            # number that describes neither. The pool deviation is carried alongside because it is
            # what decides which side is which.
            "bySide": {
                "buysBase": side_stats(True),
                "sellsBase": side_stats(False),
            },
            # And by desk, because they are not one population either. The demo desk trades a
            # mintable pair and is the tape; the hedged desk is deliberately lopsided — it absorbed
            # base and holds mostly quote, so its pool sits *thousands* of bps off L1 and one of
            # its fills would otherwise drag the aggregate poolDev with it. Medians survive that,
            # means do not, and a panel that wants one desk should be able to ask for it.
            "byDesk": {
                name: {
                    **subset_stats([r for r in rows if r["deskName"] == name]),
                    "bySide": {
                        "buysBase": subset_stats(
                            [r for r in rows if r["deskName"] == name and r["makerBuysBase"]]
                        ),
                        "sellsBase": subset_stats(
                            [r for r in rows if r["deskName"] == name and not r["makerBuysBase"]]
                        ),
                    },
                }
                for name in sorted({r["deskName"] for r in rows})
            },
        },
        "fills": rows,
        "postedThisRun": [],
        "failedThisRun": [],
    }

    if limit is not None:
        to_post = to_post[:limit]
    print(f"  {complete}/{len(rows)} fills carry a complete 5/15/60 · {len(to_post)} markouts to post")

    # Posting is best effort; writing the artifact is not. A send that fails must not take the
    # page's data down with it — the join already happened, the numbers are already correct, and
    # whatever did not get posted is simply still unposted on the next pass, which the stream
    # itself will confirm. Failing the whole run here once lost an artifact update to one
    # `replacement transaction underpriced`.
    for f, h, bps in to_post:
        print(f"  post {f.fill_id[:14]}… h={h:>2}m bps={bps:>5}")
        try:
            tx = send(
                dep, dep.markout_ledger,
                "post(bytes32,bytes32,uint8,int256)",
                [f.order_hash, f.fill_id, str(h), str(bps)],
                account=account, password_file=password_file, dry_run=dry_run,
            )
        except ChainError as e:
            print(f"    ! not posted: {e}")
            doc["failedThisRun"].append(
                {"fillId": f.fill_id, "horizonMinutes": h, "bps": bps, "error": str(e)}
            )
            continue
        if tx:
            doc["postedThisRun"].append(
                {"fillId": f.fill_id, "horizonMinutes": h, "bps": bps, "txHash": tx}
            )

    POOL_DEV_CACHE.parent.mkdir(parents=True, exist_ok=True)
    POOL_DEV_CACHE.write_text(json.dumps(dev_cache, indent=1) + "\n")

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, indent=2) + "\n")
    print(f"  wrote {out}")

    # The book series as its own artifact, so the page and the MCP server answer the same
    # question from the same numbers. It is the only file here a browser can use to say what the
    # BBO was at a past moment, because the node it would otherwise ask returns the present.
    archive = out.parent / "book-archive.json"
    archive.write_text(json.dumps({
        "generatedAt": doc["generatedAt"],
        "chainId": dep.chain_id,
        "perpIndex": 0,
        "instrument": "BTC perp BBO on Hyperliquid (HyperCore), as CoreQuote reads it",
        "source": doc["source"],
        "contract": dep.book_cache,
        "event": "BookCache.Booked(uint32,uint64,uint64,uint64,uint64,uint64,address)",
        "rawPriceScale": "USD * 10^(6 - szDecimals); BTC szDecimals 5, so divide by 10",
        "limits": {
            "interpolation": "none — consecutive observations bound the truth between them",
            "depth": "four uint64 (bid, ask, mark, oracle), not an order book",
            "beforeFirstObservation": "never written down; unrecoverable from any endpoint",
        },
        "count": len(c.books),
        "observations": [
            {"t": b.t, "block": b.block, "bid": b.bid, "ask": b.ask,
             "mark": b.mark, "oracle": b.oracle}
            for b in c.books
        ],
    }, separators=(",", ":")) + "\n")
    print(f"  wrote {archive} ({len(c.books)} observations)")
    return doc
