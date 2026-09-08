"""One RPC, one keystore, the deployed addresses. Everything else imports from here.

Standard library only, on purpose. The markout loop is the thing a judge is most likely to want
to run, and `python -m coldcascade markouts --dry-run` should not first need a virtualenv and a
compiled web3 stack. JSON-RPC over urllib is forty lines; signing is delegated to `cast`, which
is already the only thing in this repository that holds a key.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# HyperCore precompiles, from src/libs/HyperCore.sol. They have no bytecode: a fork cannot call
# them, and they ignore the block tag — an eth_call pinned 200 000 blocks back answers with the
# current book. Node state, not chain state.
MARK_PX = "0x0000000000000000000000000000000000000806"
ORACLE_PX = "0x0000000000000000000000000000000000000807"
L1_BLOCK_NUMBER = "0x0000000000000000000000000000000000000809"
BBO = "0x000000000000000000000000000000000000080e"


class ChainError(RuntimeError):
    pass


@dataclass(frozen=True)
class Deployment:
    chain_id: int
    rpc_url: str
    aqua: str
    router: str
    core_quote: str
    core_precompiles: str
    book_cache: str
    desk_hooks: str
    map_oracle: str
    markout_ledger: str
    deployed_at_block: int
    desks: dict[str, str] = field(default_factory=dict)
    raw: dict = field(default_factory=dict)


def load_deployment(chain_id: int = 999) -> Deployment:
    """Reads deployments/<chain_id>.json written by script/Deploy.s.sol."""
    path = ROOT / "deployments" / f"{chain_id}.json"
    if not path.exists():
        raise ChainError(f"no {path} — nothing is deployed on chain {chain_id}")
    d = json.loads(path.read_text())
    rpc = os.environ.get("HYPEREVM_RPC_URL", "https://rpc.hyperliquid.xyz/evm")
    return Deployment(
        chain_id=d["chainId"],
        rpc_url=rpc,
        aqua=d["aqua"],
        router=d["router"],
        core_quote=d["coreQuote"],
        core_precompiles=d["corePrecompiles"],
        book_cache=d["bookCache"],
        desk_hooks=d["deskHooks"],
        map_oracle=d["mapOracle"],
        markout_ledger=d["markoutLedger"],
        deployed_at_block=int(d["deployedAtBlock"]),
        desks={k: v for k, v in d.items() if k.endswith("Desk")},
        raw=d,
    )


# --- reads ------------------------------------------------------------------------------------

def rpc(dep: Deployment, method: str, params: list) -> object:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(
        dep.rpc_url, data=body, headers={"content-type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.loads(r.read())
    if "error" in out:
        raise ChainError(f"{method}: {out['error']}")
    return out["result"]


def call(dep: Deployment, to: str, data: str) -> bytes:
    return bytes.fromhex(rpc(dep, "eth_call", [{"to": to, "data": data}, "latest"])[2:])


def read_book(dep: Deployment, perp_index: int) -> tuple[int, int, int, int]:
    """(bid, ask, mark, oracle) in raw units, straight from the precompiles via eth_call."""
    arg = "0x" + perp_index.to_bytes(32, "big").hex()
    bbo = call(dep, BBO, arg)
    if len(bbo) != 64:
        raise ChainError(f"0x080e returned {len(bbo)} bytes for perp {perp_index}")
    bid = int.from_bytes(bbo[0:32], "big")
    ask = int.from_bytes(bbo[32:64], "big")
    mark = int.from_bytes(call(dep, MARK_PX, arg), "big")
    oracle = int.from_bytes(call(dep, ORACLE_PX, arg), "big")
    # HyperCore.book reverts on a zero in any word rather than handing a quote a bid of zero, and
    # so does this: an unreadable book is a thing you skip, never a thing you price against.
    if not all((bid, ask, mark, oracle)):
        raise ChainError(f"perp {perp_index}: unreadable book ({bid}, {ask}, {mark}, {oracle})")
    return bid, ask, mark, oracle


def desk_params(dep: Deployment, desk: str) -> dict:
    """base, quote, perpIndex and the price scale, off the desk's own frozen params."""
    out = call(dep, desk, "0xcff0ab96")  # params()
    if len(out) < 32 * 13:
        raise ChainError(f"{desk}: params() returned {len(out)} bytes")
    w = [out[i * 32:(i + 1) * 32] for i in range(13)]
    n = lambda i: int.from_bytes(w[i], "big")  # noqa: E731
    return {
        "base": "0x" + w[0][12:].hex(),
        "quote": "0x" + w[1][12:].hex(),
        "perpIndex": n(2),
        "pxNum": n(3),
        "pxDen": n(4),
        "quietBps": n(5),
    }


# --- the one write ----------------------------------------------------------------------------

def send(
    dep: Deployment,
    to: str,
    sig: str,
    args: list[str],
    account: str,
    password_file: str | None = None,
    dry_run: bool = True,
    gas_price: str = "0.15gwei",
) -> str | None:
    """Signs with the named foundry keystore. Returns the tx hash, or None on a dry run.

    Delegated to `cast` rather than reimplemented: the key never leaves the keystore, the
    signing path is the same one every other script in this repository uses, and `--legacy` is
    required because the node otherwise supplies a priority fee above its own max fee.
    """
    cast = shutil.which("cast") or str(Path.home() / ".foundry/bin/cast")
    if not Path(cast).exists():
        raise ChainError("cast not found (looked on PATH and in ~/.foundry/bin)")
    cmd = [cast, "send", to, sig, *args, "--rpc-url", dep.rpc_url,
           "--legacy", "--gas-price", gas_price, "--account", account]
    if password_file:
        cmd += ["--password-file", password_file]

    if dry_run:
        print(f"  would send: {sig} {' '.join(args)} -> {to}")
        return None

    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        # Keep stderr. A swallowed error here reads downstream as a markout nobody wanted to post.
        raise ChainError(f"cast send failed ({p.returncode}): {p.stderr.strip() or p.stdout.strip()}")
    for line in p.stdout.splitlines():
        if line.startswith("transactionHash"):
            return line.split()[1]
        if line.startswith("status") and "0 (failed)" in line:
            raise ChainError(f"transaction reverted: {p.stdout}")
    raise ChainError(f"no transactionHash in cast output: {p.stdout}")
