"""Rebuilds tape/oct10_btc_1m.json from public sources.

Hyperliquid's S3 node fill log carries the `liquidation` object per fill (the only place it is
attributed); Coinbase 1m candles give spot. The oracle is approximated by Coinbase close and the
bid/ask by mark -/+ half the quiet spread; both are stated limits, not hidden ones.
"""

from pathlib import Path


def fetch_hl_fills(coin: str, day: str, cache_dir: Path) -> Path:
    """Downloads one UTC day of the fill log for `coin` into cache_dir. Idempotent."""
    raise NotImplementedError("todo")


def fetch_coinbase_candles(product: str, day: str, cache_dir: Path) -> Path:
    """Downloads one UTC day of 1m candles for `product` into cache_dir. Idempotent."""
    raise NotImplementedError("todo")


def build_minutes(fills_path: Path, candles_path: Path, quiet_spread_raw: int) -> list[dict]:
    """One record per minute in the schema of tape/oct10_btc_1m.schema.json."""
    raise NotImplementedError("todo")


def onset_minute(minutes: list[dict], forced_share_threshold: float) -> int:
    """The first minute whose forced share of taker flow crosses the threshold. Chosen by the
    data, never typed in."""
    raise NotImplementedError("todo")


def write_tape(minutes: list[dict], out_path: Path) -> None:
    raise NotImplementedError("todo")
