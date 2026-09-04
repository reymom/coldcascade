"""The one trusted write. Forced notional within 1% of mark on each side, from Hyperliquid's own
open-interest and margin data, written to MapOracle.update() with a timestamp. If this stops, the
desk quotes book-only; it can never lean on a word older than the maker's mapMaxAge."""

from .chain import Deployment


def reconstruct_map(perp_index: int, mark_raw: int) -> tuple[int, int]:
    """(belowNotional, aboveNotional) in USD for the next 1% down and up."""
    raise NotImplementedError("todo")


def update_once(dep: Deployment, perp_index: int, account: str, dry_run: bool = True) -> str | None:
    raise NotImplementedError("todo")


def run(dep: Deployment, perp_index: int, account: str, interval_s: int) -> None:
    raise NotImplementedError("todo")
