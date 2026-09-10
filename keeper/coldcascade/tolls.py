"""What the same searcher would have taken out of three makers, over the same fills.

A maker is arbitraged when somebody can trade against it and unwind at the reference venue for
more than they paid. That difference is the maker's toll, and it exists because the maker's price
was set at some earlier moment than the trade that took it. This module puts a number on it for
each fill the desks actually signed, against three prices:

  * **desk** — the price the fill printed at. Read out of the fill itself, so it is not a
    counterfactual at all: it is what happened.
  * **flatCurve** — a plain constant-product curve on the desk's own reserves at that block. The
    ablation: `desk()` with the bound removed, priced off the same reserves.
  * **oraclePegged** — a maker whose price *is* the oracle, refreshed on a cadence and still in
    between. This is what most on-chain makers on a perps venue are, and it is the comparison a
    reader will not call a straw man.

The searcher is the same one in all three cases and it is generous to the maker on both counts
that matter: it closes at Hyperliquid's own touch, with no fee and with infinite depth. A real
exit is worse than that, so a real round trip pays less than the number here, which makes every
toll below a floor rather than an estimate.

    maker buys base   sell base to it at its bid, buy it back at L1's ask   (bid  - ask) / ask
    maker sells base  buy base from it at its ask, sell into L1's bid       (bid - ask') / bid

Positive is the searcher being paid; a negative round trip means there was nothing to take and the
toll for that fill is zero, not a credit. The size is the fill's own size, so this answers "what
would that trade have cost this maker", not "how much could a searcher have extracted in total".

**The cadence is the whole argument, so it is declared next to the number.** An oracle-pegged
maker bleeds exactly in proportion to how long it goes between refreshes; a toll quoted without
its cadence is not a measurement of anything. The shipped cadence refreshes on **every book
observation this repository wrote** — a poke a minute, which is the fastest this series can
express — so the number it produces is the friendliest one the data can support and any real
maker does worse. `CADENCE_SWEEP` publishes what slower ones cost, and `reference` swaps the
oracle for mark to answer the obvious objection that the oracle was the unkind choice.
"""

from __future__ import annotations

import bisect
from dataclasses import dataclass

# BTC has szDecimals 5, so a raw HyperCore price is USD * 10. UBTC is 8 decimals. Both are
# properties of the pair every desk in `deployments/999.json` lists, and `book-archive.json`
# carries the same sentence next to the series these prices come from.
RAW_PER_USD = 10
BASE_DECIMALS = 8

# How stale the *series* may be at the moment of a fill before the peg stops being knowable. This
# is not the cadence: it is whether this repository was watching. Past it the maker would have
# refreshed off an oracle nobody wrote down, so the fill is reported as `gap` and left out of the
# sum rather than priced off a number from twenty minutes earlier. Two minutes is the same floor
# `markouts.tolerance_s` uses, and for the same reason — it is two poke intervals.
SERIES_TOLERANCE_S = 120

# A pool ratio further than this from L1 is not a maker quoting, it is the reserves a strategy
# happened to be shipped with. Two fills in the corpus are that: the hedged desk at +90 656 bps
# and the operator desk at +167 764, both of them takes this repository sent to build an exposure
# for the hedge to cover. Left in, either one is worth more toll on its own than every other fill
# together, and the flat curve's total stops describing a curve. They keep their per-fill numbers;
# only the totals name the subset, and say so.
CURVE_SANITY_BPS = 10_000


@dataclass(frozen=True)
class Cadence:
    """When an oracle-pegged maker moves its price, and off what.

    `deviation_bps` is the move that forces a refresh and `heartbeat_s` the longest it will go
    without one — the two dials a pushed price feed is configured with. Zero deviation means the
    deviation trigger is off and the heartbeat alone moves the price, which is how a feed with no
    threshold configured behaves and is also the only way to express "every observation" here.

    `band_bps` is how far either side of the peg the maker quotes. `None` means the fill's own
    `quietBps`, which is what makes the headline a like-for-like comparison: the desk and this
    maker quote the same width and differ only in what the width is measured from. It is a dial
    all the same, and a sweep that moved the cadence without moving it would be hiding the half of
    the answer that turns out to matter more.
    """

    name: str
    deviation_bps: float
    heartbeat_s: int
    reference: str = "oracle"
    band_bps: float | None = None

    def as_json(self) -> dict:
        return {
            "name": self.name,
            "deviationBps": self.deviation_bps,
            "heartbeatSeconds": self.heartbeat_s,
            "reference": self.reference,
            "bandBps": "the fill's own quietBps" if self.band_bps is None else self.band_bps,
        }


# What the number at the top of the page is computed with. Refresh on every observation: this
# repository pokes `BookCache` about once a minute, so no maker reading this chain could have been
# faster, and the toll below is therefore a floor on what an oracle-pegged maker pays.
SHIPPED_CADENCE = Cadence("every-observation", 0.0, 60, "oracle")

# And what the same makers pay at cadences a real one is more likely to run. The last row is the
# same maker pegged to mark instead of the oracle — the reference that tracks the book rather than
# the one that tracks fair value — because "you picked the unkind number" is the first thing a
# reader will say about the row above it.
CADENCE_SWEEP = (
    SHIPPED_CADENCE,
    Cadence("five-minute", 0.0, 300, "oracle"),
    Cadence("fifteen-minute", 0.0, 900, "oracle"),
    Cadence("deviation-25bps-hourly", 25.0, 3600, "oracle"),
    Cadence("deviation-50bps-hourly", 50.0, 3600, "oracle"),
    Cadence("every-observation-on-mark", 0.0, 60, "mark"),
    # And the other dial. A maker quoting twenty basis points either side of BTC is wide, and a
    # wide quote is most of why the row at the top of this table is a zero. These are the same
    # cadence at the widths a maker that wanted the flow would actually run.
    Cadence("every-observation-band-10bps", 0.0, 60, "oracle", 10.0),
    Cadence("every-observation-band-5bps", 0.0, 60, "oracle", 5.0),
    Cadence("every-observation-band-0bps", 0.0, 60, "oracle", 0.0),
    Cadence("fifteen-minute-band-5bps", 0.0, 900, "oracle", 5.0),
)


def peg_steps(observations: list[dict], cadence: Cadence) -> tuple[list[int], list[float]]:
    """The peg as a step function of time: when it moved, and what to.

    One pass over the series in time order. The first observation arms the maker; after that a
    refresh needs either the deviation or the heartbeat, which is exactly how a pushed feed
    behaves and exactly why one is stale between updates.
    """
    times: list[int] = []
    pegs: list[float] = []
    peg: float | None = None
    peg_at = 0

    for o in observations:
        px = o.get(cadence.reference)
        t = o.get("t")
        if not px or t is None:
            continue
        if peg is None:
            fire = True
        else:
            moved = abs(px - peg) / peg * 10_000.0
            fire = (cadence.deviation_bps > 0 and moved >= cadence.deviation_bps) or (
                t - peg_at
            ) >= cadence.heartbeat_s
        if fire:
            peg, peg_at = float(px), int(t)
            times.append(peg_at)
            pegs.append(peg)
    return times, pegs


def peg_at(times: list[int], pegs: list[float], t: int) -> tuple[float, int] | None:
    """The price this maker was quoting off at `t`: the last refresh at or before it."""
    i = bisect.bisect_right(times, t) - 1
    if i < 0:
        return None
    return pegs[i], times[i]


def _round_trip_bps(px_raw: float, fill: dict) -> float:
    """Where a searcher's round trip against a maker quoting `px_raw` comes out, in bps.

    Signed. Negative is the ordinary case — the maker is inside the venue it would be closed
    against — and it is left signed here so a caller can see how far under water the trip was
    rather than only that it did not pay.
    """
    if fill["makerBuysBase"]:
        ask = fill["askRaw"]
        return (px_raw - ask) / ask * 10_000.0
    bid = fill["bidRaw"]
    return (bid - px_raw) / bid * 10_000.0


def _toll(px_raw: float | None, fill: dict, status: str, extra: dict | None = None) -> dict:
    """One line's price on one fill, and what it cost it."""
    row: dict = {"status": status, "usd": None, "bps": None, "pxRaw": None}
    if extra:
        row.update(extra)
    if status != "ok" or px_raw is None:
        return row

    bps = _round_trip_bps(px_raw, fill)
    notional = int(fill["baseRaw"]) / 10**BASE_DECIMALS * (fill["midRaw"] / RAW_PER_USD)
    row["pxRaw"] = round(px_raw, 2)
    row["bps"] = round(bps, 3)
    row["usd"] = round(max(bps, 0.0) / 10_000.0 * notional, 4)
    return row


def desk_toll(fill: dict) -> dict:
    """The price the fill actually printed at, put through the same round trip as the others.

    `vsTouchBps` is where the fill printed against the touch it dealt at, so the executed price is
    that touch moved by it. Nothing here is counterfactual: this is the receipt.
    """
    vs = fill.get("vsTouchBps")
    if fill.get("bookOk") is False or vs is None:
        return _toll(None, fill, "noBook")
    return _toll(fill["touchRaw"] * (1 + vs / 10_000.0), fill, "ok")


def flat_curve_toll(fill: dict) -> dict:
    """A plain constant-product curve on the same reserves, at the same block.

    `poolDevBps` is where those reserves sat against L1 *before* the fill, and `markouts.pool_dev_bps`
    measures it against the fill's own **oracle** word — so the curve's price is the oracle moved by
    it, not the mid moved by it. The two differ by half the L1 spread, which is small against the
    deviation but is not nothing, and using the mid here would be quoting a number off a basis it
    was not measured on.
    """
    dev = fill.get("poolDevBps")
    if fill.get("bookOk") is False:
        return _toll(None, fill, "noBook")
    if dev is None:
        return _toll(None, fill, "noReserves")
    base = fill.get("oracleRaw") or fill["midRaw"]
    basis = "oracle" if fill.get("oracleRaw") else "mid"
    return _toll(base * (1 + dev / 10_000.0), fill, "ok", {"basis": basis})


def oracle_pegged_toll(
    fill: dict,
    times: list[int],
    pegs: list[float],
    last_observation_at,
    series_start: int | None,
    band_bps: float | None = None,
) -> dict:
    """A maker whose price is the oracle at its last refresh, plus and minus the desk's own band.

    The band is the fill's own `quietBps` rather than a number chosen here, which is what makes
    this a comparison rather than two makers with different appetites: the desk and this maker
    quote the **same width**, and the only difference between them is what that width is measured
    from. The desk's is centred on the book read inside the call that settles the swap. This one's
    is centred on an oracle print from up to one cadence ago.
    """
    if fill.get("bookOk") is False:
        return _toll(None, fill, "noBook")

    t = fill["at"]
    if series_start is not None and t < series_start:
        # The eight fills older than the first poke can never acquire a peg: `BookCache` had never
        # been called on 999 and there is no Booked event before it. Not a hole — a beginning.
        return _toll(None, fill, "beforeSeries")

    seen = last_observation_at(t)
    if seen is None or t - seen > SERIES_TOLERANCE_S:
        return _toll(None, fill, "gap", {"seriesAgeSeconds": None if seen is None else t - seen})

    found = peg_at(times, pegs, t)
    if found is None:
        return _toll(None, fill, "beforeSeries")
    peg, at = found

    band = (fill.get("quietBps") or 0) if band_bps is None else band_bps
    px = peg * (1 - band / 10_000.0) if fill["makerBuysBase"] else peg * (1 + band / 10_000.0)
    return _toll(px, fill, "ok", {
        "pegRaw": peg,
        "pegAt": at,
        "pegAgeSeconds": t - at,
        "bandBps": band,
    })


def _total(rows: list[dict], line: str) -> dict:
    """The accumulated toll for one line, and how many fills the sum is over."""
    cells = [r["toll"][line] for r in rows if r.get("toll")]
    priced = [c for c in cells if c["status"] == "ok"]
    paying = [c for c in priced if c["usd"] > 0]
    out = {
        "tollUsd": round(sum(c["usd"] for c in priced), 2),
        "fills": len(cells),
        "priced": len(priced),
        "paying": len(paying),
        "worstFillUsd": round(max((c["usd"] for c in priced), default=0.0), 2),
    }
    for label in ("noBook", "noReserves", "beforeSeries", "gap"):
        n = sum(1 for c in cells if c["status"] == label)
        if n:
            out[label] = n
    return out


def counterfactuals(
    rows: list[dict],
    observations: list[dict],
    cadence: Cadence = SHIPPED_CADENCE,
    sweep: tuple[Cadence, ...] = CADENCE_SWEEP,
) -> dict:
    """Attach a `toll` block to every fill and return the summary that goes beside them.

    `rows` are the fill rows of `results/markouts.json`, mutated in place; `observations` are the
    `{t, bid, ask, mark, oracle}` records of `results/book-archive.json`, in time order.
    """
    obs = sorted((o for o in observations if o.get("t") is not None), key=lambda o: o["t"])
    obs_times = [o["t"] for o in obs]
    series_start = obs_times[0] if obs_times else None

    def last_observation_at(t: int):
        i = bisect.bisect_right(obs_times, t) - 1
        return obs_times[i] if i >= 0 else None

    times, pegs = peg_steps(obs, cadence)

    for r in rows:
        r["toll"] = {
            "desk": desk_toll(r),
            "flatCurve": flat_curve_toll(r),
            "oraclePegged": oracle_pegged_toll(r, times, pegs, last_observation_at, series_start),
        }

    quoting = [r for r in rows if abs(r.get("poolDevBps") or 0.0) <= CURVE_SANITY_BPS]
    excluded = [
        {
            "txHash": r["txHash"],
            "deskName": r["deskName"],
            "poolDevBps": r["poolDevBps"],
            "why": "the reserves the strategy was shipped with, not a price a quote set",
        }
        for r in rows
        if r not in quoting
    ]

    def totals(rs: list[dict]) -> dict:
        return {line: _total(rs, line) for line in ("desk", "flatCurve", "oraclePegged")}

    return {
        "note": (
            "What the same searcher would have taken out of three makers over the same fills, at "
            "each fill's own size. The searcher closes at Hyperliquid's touch with no fee and no "
            "depth, which is the most generous exit there is, so every number here is a floor."
        ),
        "searcher": {
            "exit": "L1 touch — the bid for base it is selling, the ask for base it is buying",
            "fee": 0,
            "depth": "infinite, and free",
            "size": "the fill's own size",
            "roundTrip": (
                "maker buys base: (makerBid - ask) / ask · maker sells base: (bid - makerAsk) / bid"
            ),
        },
        "rawPriceScale": "USD * 10^(6 - szDecimals); BTC szDecimals 5, so divide by 10",
        "lines": {
            "desk": {
                "what": "the price the fill printed at — the receipt, not a counterfactual",
                **totals(quoting)["desk"],
            },
            "flatCurve": {
                "what": (
                    "a plain constant-product curve on the desk's own reserves at that block, "
                    "priced off the oracle the deviation was measured against"
                ),
                **totals(quoting)["flatCurve"],
            },
            "oraclePegged": {
                "what": (
                    "a maker whose price is the oracle at its last refresh, quoting the desk's own "
                    "band either side of it and standing still in between"
                ),
                "cadence": cadence.as_json(),
                "band": "the fill's own quietBps, so the two makers quote the same width",
                **totals(quoting)["oraclePegged"],
            },
        },
        "over": {
            "fills": len(quoting),
            "rule": f"|poolDevBps| <= {CURVE_SANITY_BPS}",
            "why": (
                "a pool ratio further from L1 than this is not a maker quoting, it is the reserves "
                "a strategy was shipped with. Both such fills are takes this repository sent to "
                "build an exposure for the hedge to cover; either one alone is worth more toll "
                "than every other fill together. Their per-fill numbers stay on the fills."
            ),
            "excluded": excluded,
        },
        "cadenceSweep": [
            _sweep_row(rows, quoting, obs, c, last_observation_at, series_start) for c in sweep
        ],
    }


def _sweep_row(
    rows: list[dict],
    quoting: list[dict],
    obs: list[dict],
    cadence: Cadence,
    last_observation_at,
    series_start: int | None,
) -> dict:
    """The oracle-pegged toll at one cadence, computed the same way and reported beside the rest.

    The point of the sweep is that the headline is not a fact about oracle makers, it is a fact
    about oracle makers *at that cadence*. Anyone who thinks the cadence was chosen to flatter the
    desk can read the row they would have chosen instead.
    """
    times, pegs = peg_steps(obs, cadence)
    cells = [
        oracle_pegged_toll(r, times, pegs, last_observation_at, series_start, cadence.band_bps)
        for r in quoting
    ]
    priced = [c for c in cells if c["status"] == "ok"]
    return {
        **cadence.as_json(),
        "refreshes": len(times),
        "tollUsd": round(sum(c["usd"] for c in priced), 2),
        "priced": len(priced),
        "paying": sum(1 for c in priced if c["usd"] > 0),
    }


# --- rebuilding the block on an artifact that already exists -----------------------------------


def _oracle_by_tx(events_path) -> dict[str, dict]:
    """The `mark` and `oracle` words of every fill the stream has seen, by transaction.

    `DeskHooks.Fill` carries the whole book the quote read — bid, ask, mark and oracle — and
    `results/desk-events.jsonl` keeps all four. `results/markouts.json` kept only the two sides of
    the touch, so this is where the other two come back. A fill the stream has not written down
    yet simply does not get them, and nothing below needs them: the peg comes from the series, not
    from the fill.
    """
    out: dict[str, dict] = {}
    if not events_path.exists():
        return out
    import json as _json

    for line in events_path.read_text().splitlines():
        if not line.strip():
            continue
        blk = _json.loads(line)
        for f in blk.get("fills") or []:
            out[f["txHash"].lower()] = {
                "markRaw": int(f["mark"]),
                "oracleRaw": int(f["oracle"]),
            }
    return out


def apply_to_artifact(markouts_path, archive_path, events_path) -> dict:
    """Recompute the counterfactual block against artifacts that are already on disk.

    The cadence run computes this inline, off the corpus it just streamed. This is the same
    computation over the files that run left behind, so the number can be reproduced — and the
    cadence changed — without a node, a key, or the network. Nothing here reads the chain.
    """
    import json as _json

    doc = _json.loads(markouts_path.read_text())
    archive = _json.loads(archive_path.read_text())
    words = _oracle_by_tx(events_path)

    for r in doc["fills"]:
        # A run of the cadence writes these straight off the stream, so they are only filled in
        # from the events file when they are missing — a rebuild must never take a number *out*
        # of the artifact, and `desk-events.jsonl` can be a pass or two behind `markouts.json`.
        seen = words.get(r["txHash"].lower())
        for word in ("markRaw", "oracleRaw"):
            if r.get(word) is None:
                r[word] = seen[word] if seen else None

    doc["counterfactuals"] = counterfactuals(doc["fills"], archive["observations"])
    markouts_path.write_text(_json.dumps(doc, indent=2) + "\n")
    return doc
