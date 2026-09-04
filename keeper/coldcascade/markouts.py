"""Read Graph, decide, write chain.

Fills come from the subgraph (DeskHooks.Fill with the book they were filled against); the later
book comes from the same subgraph (BookCache.Booked). The markout of a fill at horizon h is the
signed move of mid from fill to fill+h, in bps, from the maker's side. Posted to MarkoutLedger and
written to results/markouts.json for the page."""

from dataclasses import dataclass

from .chain import Deployment

HORIZONS_MIN = (5, 15, 60)


@dataclass(frozen=True)
class Fill:
    fill_id: str
    order_hash: str
    t: int
    maker_buys_base: bool
    amount_in: int
    amount_out: int
    bid: int
    ask: int
    mark: int
    oracle: int


def fetch_fills(subgraph_url: str, since_t: int) -> list[Fill]:
    raise NotImplementedError("todo")


def fetch_mid_at(subgraph_url: str, perp_index: int, t: int) -> int | None:
    """Mid of the first Booked at or after t. None if the series has not reached t yet."""
    raise NotImplementedError("todo")


def markout_bps(fill: Fill, mid_later: int) -> int:
    raise NotImplementedError("todo")


def post_once(dep: Deployment, subgraph_url: str, account: str, dry_run: bool = True) -> list[str]:
    raise NotImplementedError("todo")
