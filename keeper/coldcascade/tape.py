"""Rebuilds tape/oct10_btc_1m.json from public sources.

Hyperliquid's S3 node fill log carries the `liquidation` object per fill (the only place it is
attributed); Coinbase 1m candles give spot. The oracle is approximated by Coinbase close and the
bid/ask by mark -/+ half the quiet spread; both are stated limits, not hidden ones.

The window is not a matter of taste. A markout needs a later spot, so the tape has to run at least
`TAIL_MINUTES` past the last minute that produced a fill or the longest markout column is
structurally zero and the screen shows only the half of the trade that loses. `select_window`
enforces that and `covers_markout` refuses to write a tape that does not.
"""

import json
import time
import urllib.request
from pathlib import Path
from statistics import median

#: The markout horizons the replay reports, in minutes. Mirrors test/Oct10Replay.t.sol.
MARKOUT_HORIZONS_MINUTES = (5, 15, 60)

#: Minutes of tape that must follow the last fill for every markout column to exist.
TAIL_MINUTES = max(MARKOUT_HORIZONS_MINUTES)

#: Minutes of quiet tape before the onset, so the screen has a flat stretch to depart from.
LEAD_MINUTES = 10

#: Raw HyperCore units per USD for an asset with szDecimals 5, which is BTC. price = raw / RAW_PER_USD.
RAW_PER_USD = 10

COINBASE_CANDLES = "https://api.exchange.coinbase.com/products/{product}/candles"
COINBASE_MAX_CANDLES = 300


class TapeTooShort(Exception):
    """The tape does not reach far enough past its last fill to carry every markout."""


def fetch_hl_fills(coin: str, day: str, cache_dir: Path) -> Path:
    """Downloads one UTC day of the fill log for `coin` into cache_dir. Idempotent.

    The only public source that attributes a fill to a liquidation is the S3 node archive
    (`s3://hyperliquid-archive`, requester-pays), not the info API: `candleSnapshot` retains
    roughly the last 5 000 minutes and returns nothing for 2025-10-10 at all, checked
    2026-09-05. Until this lands the forced columns come from `forced_overlay`.
    """
    raise NotImplementedError("todo: s3://hyperliquid-archive, requester-pays")


def fetch_coinbase_candles(product: str, start: int, end: int, cache_dir: Path) -> Path:
    """Downloads 1m candles for `product` over [start, end) unix seconds. Idempotent.

    Coinbase serves at most 300 candles per request and rejects a wider window outright, so this
    pages backwards through the range. Rows come back newest first and unsorted across pages;
    the cache holds them sorted ascending by open time.
    """
    cache_dir.mkdir(parents=True, exist_ok=True)
    out = cache_dir / f"{product}_{start}_{end}_1m.json"
    if out.exists():
        return out

    rows: dict[int, list] = {}
    span = COINBASE_MAX_CANDLES * 60
    for page_start in range(start, end, span):
        page_end = min(page_start + span, end)
        url = (
            f"{COINBASE_CANDLES.format(product=product)}?granularity=60"
            f"&start={_iso(page_start)}&end={_iso(page_end)}"
        )
        req = urllib.request.Request(url, headers={"user-agent": "coldcascade/0.0.1"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            for row in json.load(resp):
                rows[int(row[0])] = row
        time.sleep(0.25)  # the public endpoint rate-limits well below what this needs

    out.write_text(json.dumps([rows[t] for t in sorted(rows)]) + "\n")
    return out


def build_minutes(
    candles_path: Path,
    quiet_spread_raw: int,
    fills_path: Path | None = None,
) -> list[dict]:
    """One record per minute in the schema of tape/oct10_btc_1m.schema.json.

    Spot and oracle are the Coinbase close: Hyperliquid's oracle is a median of CEX prices and
    Coinbase is the largest term in it, which is an approximation and is stated as one. Mark is
    the perp's own print; with no fill log it falls back to spot, so `mark == oracle` and the
    book alone never declares stress. Bid and ask are mark -/+ half the quiet spread, flat,
    which is the tape's other stated limit.

    Without `fills_path` the forced columns are zero and `takerNtl` is the Coinbase volume in
    USD. That is a price tape, not a cascade tape: `forced_overlay` is what makes it one until
    the S3 fill log lands.
    """
    if fills_path is not None:
        raise NotImplementedError("todo: attribute forced notional from the fill log")

    candles = json.loads(candles_path.read_text())
    half = quiet_spread_raw // 2
    minutes = []
    for t, _low, _high, _open, close, volume in candles:
        px = round(float(close) * RAW_PER_USD)
        minutes.append(
            {
                "ask": px + half,
                "bid": px - half,
                "forcedBuyNtl": 0,
                "forcedSellNtl": 0,
                "mark": px,
                "oracle": px,
                "spot": px,
                "t": int(t),
                "takerNtl": round(float(volume) * float(close)),
            }
        )
    return minutes


def onset_minute(minutes: list[dict], forced_share_threshold: float) -> int:
    """The first minute whose forced share of taker flow crosses the threshold. Chosen by the
    data, never typed in."""
    for i, m in enumerate(minutes):
        taker = m["takerNtl"]
        if taker <= 0:
            continue
        forced = m["forcedSellNtl"] + m["forcedBuyNtl"]
        if forced / taker >= forced_share_threshold:
            return i
    raise ValueError("no minute crosses the forced-share threshold")


def last_forced_minute(minutes: list[dict]) -> int:
    """The last minute carrying forced flow. The markout tail is measured from here, because this
    is the last minute that can produce a fill."""
    for i in range(len(minutes) - 1, -1, -1):
        if minutes[i]["forcedSellNtl"] or minutes[i]["forcedBuyNtl"]:
            return i
    raise ValueError("no minute carries forced flow")


def select_window(
    minutes: list[dict],
    onset: int,
    lead: int = LEAD_MINUTES,
    tail: int = TAIL_MINUTES,
) -> list[dict]:
    """`lead` quiet minutes before the onset through `tail` minutes after the last forced minute.

    The tail is the whole point: the desk's case is that it holds what it absorbed and is right an
    hour later, and an hour later has to be on the tape for anyone to see it.
    """
    if onset < 0 or onset >= len(minutes):
        raise ValueError(f"onset {onset} outside the tape")
    start = max(0, onset - lead)
    stop = last_forced_minute(minutes) + tail + 1
    if stop > len(minutes):
        raise TapeTooShort(
            f"need {stop} minutes to carry a {tail} minute tail, the source has {len(minutes)}"
        )
    return minutes[start:stop]


def covers_markout(minutes: list[dict], tail: int = TAIL_MINUTES) -> bool:
    """True when every minute that can produce a fill has `tail` minutes of tape after it."""
    try:
        return last_forced_minute(minutes) + tail < len(minutes)
    except ValueError:
        return False


def write_tape(minutes: list[dict], out_path: Path) -> None:
    if not covers_markout(minutes):
        raise TapeTooShort(
            f"the last forced minute is at index {last_forced_minute(minutes)} of "
            f"{len(minutes)}: a {TAIL_MINUTES} minute markout would be structurally zero"
        )
    keys = sorted(minutes[0])
    ordered = [{k: m[k] for k in keys} for m in minutes]
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(ordered, indent=2) + "\n")


def _iso(unix_seconds: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(unix_seconds))


# ---------------------------------------------------------------------------
# The synthetic overlay
#
# Everything below turns a price tape into a cascade tape without the fill log. It exists so the
# replay and the page have something with the right shape to be built against; it is not a
# reconstruction and nothing measured on it may be quoted. `fetch_hl_fills` retires it.
# ---------------------------------------------------------------------------

#: Bps of perp-to-oracle dislocation per bp of adverse minute return. The perp leads the CEX in
#: both directions during a cascade; this is the crudest possible statement of that.
DISLOCATION_GAIN = 0.5
DISLOCATION_CAP_BPS = 300.0

#: Bps the book widens per bp of adverse move, over the quiet spread measured on 999.
SPREAD_GAIN = 0.6

#: Share of the minute's flow that is forced, per bp of adverse move, and its ceiling.
FORCED_SHARE_PER_BPS = 1 / 500
FORCED_SHARE_CAP = 0.6

#: A minute is forced when it moves this many times the session's own median minute move. Set as
#: a multiple rather than a bps figure so the tape picks its own threshold: 2025-10-10 ran a
#: median of 5.3 bps a minute before the onset, which puts the line at about 45 bps.
#:
#: Without a floor of some kind every minute with any move at all is a forced minute, the tape
#: never goes quiet again, and there is no tail left to measure a markout against.
FORCED_MIN_MULTIPLE = 8.0


def forced_overlay(minutes: list[dict], quiet_spread_raw: int) -> list[dict]:
    """Derives mark, the book and the forced columns from the real spot path.

    Spot, oracle and takerNtl stay as they came from Coinbase. Mark is walked off oracle in
    proportion to the minute's return, so a fast down minute puts the perp below the CEX and a
    fast up minute puts it above; the book widens with the same move and the forced notional is a
    share of the minute's flow, above a threshold the session sets for itself. Deterministic:
    same candles, same tape.
    """
    returns = _minute_returns_bps(minutes)
    threshold = FORCED_MIN_MULTIPLE * median(abs(r) for r in returns)

    out = []
    for i, m in enumerate(minutes):
        ret_bps = returns[i]
        adverse = abs(ret_bps)

        disloc = max(-DISLOCATION_CAP_BPS, min(DISLOCATION_CAP_BPS, -ret_bps * DISLOCATION_GAIN))
        oracle = m["oracle"]
        mark = round(oracle * (1 - disloc / 10_000))

        spread = max(quiet_spread_raw, round(mark * (adverse * SPREAD_GAIN) / 10_000))
        share = min(FORCED_SHARE_CAP, adverse * FORCED_SHARE_PER_BPS) if adverse >= threshold else 0.0
        forced = round(m["takerNtl"] * share)

        out.append(
            {
                **m,
                "mark": mark,
                "bid": mark - spread // 2,
                "ask": mark + spread - spread // 2,
                "forcedSellNtl": forced if ret_bps < 0 else 0,
                "forcedBuyNtl": forced if ret_bps > 0 else 0,
            }
        )
    return out


def build_stub_tape(
    cache_dir: Path,
    out_path: Path,
    product: str = "BTC-USD",
    start: int = 1_760_122_800,  # 2025-10-10 19:00 UTC
    end: int = 1_760_148_000,    # 2025-10-11 02:00 UTC
    quiet_spread_raw: int = 10,
    forced_share_threshold: float = 0.05,
) -> list[dict]:
    """Real Coinbase spot for the Oct-10 cascade, a synthetic book and forced flow over it, cut to
    a window that carries the full markout tail.

    The default span is wide enough that `select_window` has an hour of quiet to cut the tail from
    rather than running off the end of the source.
    """
    candles = fetch_coinbase_candles(product, start, end, cache_dir)
    minutes = forced_overlay(build_minutes(candles, quiet_spread_raw), quiet_spread_raw)
    window = select_window(minutes, onset_minute(minutes, forced_share_threshold))
    write_tape(window, out_path)
    return window


def _minute_returns_bps(minutes: list[dict]) -> list[float]:
    """Return of each minute's spot against the one before it, in bps. The first minute is flat."""
    out = []
    for i, m in enumerate(minutes):
        prev = minutes[i - 1]["spot"] if i else m["spot"]
        out.append((m["spot"] - prev) * 10_000 / prev if prev else 0.0)
    return out
