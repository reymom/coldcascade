"""BookCache.poke() on a cadence. The fallback read path if nested STATICCALL fails, and the Booked
series the subgraph needs for markouts either way. Anyone can run this."""

from .chain import Deployment


def poke_once(dep: Deployment, perp_index: int, account: str, dry_run: bool = True) -> str | None:
    raise NotImplementedError("todo")


def run(dep: Deployment, perp_index: int, account: str, interval_s: int) -> None:
    raise NotImplementedError("todo")
