"""One RPC, one keystore, the deployed addresses. Everything else imports from here."""

from dataclasses import dataclass


@dataclass(frozen=True)
class Deployment:
    chain_id: int
    rpc_url: str
    aqua: str
    router: str
    core_quote: str
    reader: str
    desk_hooks: str
    map_oracle: str
    markout_ledger: str
    ubtc: str
    usdt0: str


def load_deployment(chain_id: int) -> Deployment:
    """Reads deployments/<chain_id>.json written by script/Deploy.s.sol."""
    raise NotImplementedError("todo")


def read_book(dep: Deployment, perp_index: int) -> tuple[int, int, int, int]:
    """(bid, ask, mark, oracle) in raw units, straight from the precompiles via eth_call."""
    raise NotImplementedError("todo")


def send(dep: Deployment, to: str, calldata: bytes, account: str, dry_run: bool = True) -> str | None:
    """Signs with the named foundry keystore. Returns the tx hash, or None on a dry run."""
    raise NotImplementedError("todo")
