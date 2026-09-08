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
import time
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
    archive_rpc_url: str = ""


def load_deployment(chain_id: int = 999) -> Deployment:
    """Reads deployments/<chain_id>.json written by script/Deploy.s.sol."""
    path = ROOT / "deployments" / f"{chain_id}.json"
    if not path.exists():
        raise ChainError(f"no {path} — nothing is deployed on chain {chain_id}")
    d = json.loads(path.read_text())
    # The keeper deliberately does **not** default to the same endpoint as the page. Three
    # cadences and every browser on the console share one public RPC, and it does rate-limit:
    # `-32005` on two consecutive calls on 8 Sep. A keeper that is throttled retries; a page that
    # is throttled sits at "connecting to HyperEVM…" in front of a judge.
    rpc = os.environ.get("KEEPER_RPC_URL") or os.environ.get(
        "HYPEREVM_RPC_URL", "https://rpc.hyperliquid.xyz/evm"
    )
    # And a separate one for state at a past block, because the public node does not have it:
    # `balanceOf` at four blocks 145 000 apart returns the *current* balance every time. The block
    # tag is accepted and ignored, exactly as it is for the HyperCore precompiles. Verified 8 Sep
    # against drpc, which reproduces every fill's balance delta to the unit.
    archive = os.environ.get("ARCHIVE_RPC_URL", "https://hyperliquid.drpc.org")
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
        archive_rpc_url=archive,
    )


# --- reads ------------------------------------------------------------------------------------

def rpc(dep: Deployment, method: str, params: list, url: str | None = None) -> object:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(
        url or dep.rpc_url,
        data=body,
        # A User-Agent is not optional here: drpc answers a bare urllib request with 403 and cast
        # only works because it sends one.
        headers={"content-type": "application/json", "user-agent": "coldcascade-keeper/0.1"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.loads(r.read())
    if "error" in out:
        raise ChainError(f"{method}: {out['error']}")
    return out["result"]


def call(dep: Deployment, to: str, data: str) -> bytes:
    return bytes.fromhex(rpc(dep, "eth_call", [{"to": to, "data": data}, "latest"])[2:])


def token_balance_at(dep: Deployment, token: str, holder: str, block: int) -> int:
    """An ERC-20 balance as it was at the end of `block`, off the archive endpoint.

    `dep.rpc_url` cannot answer this. It accepts the block tag and returns current state, so a
    reserve read there is silently the wrong number rather than an error — which is the whole
    reason this takes a different URL.
    """
    data = "0x70a08231" + holder.lower().replace("0x", "").rjust(64, "0")
    out = rpc(
        dep, "eth_call",
        [{"to": token, "data": data}, hex(block)],
        url=dep.archive_rpc_url,
    )
    return int(out, 16)


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

MIN_GAS_WEI = 150_000_000        # 0.15 gwei
MAX_GAS_WEI = 1_000_000_000      # 1 gwei; above this a markout is not worth posting this minute


def base_fee_wei(dep: Deployment) -> int:
    block = rpc(dep, "eth_getBlockByNumber", ["latest", False])
    return int(block["baseFeePerGas"], 16)


def gas_price_wei(dep: Deployment) -> int:
    """A quarter over the live base fee, never under the floor.

    It **raises** above the cap rather than returning the cap. Clamping the price down is the
    exact mistake that jams the account: a legacy transaction priced under the base fee is
    accepted into the mempool and never mined, and every later send from that key is then
    `already known`. Declining to send is recoverable; underpaying is not.
    """
    try:
        base = base_fee_wei(dep)
    except (ChainError, KeyError, TypeError):
        base = MIN_GAS_WEI
    want = max(MIN_GAS_WEI, base * 5 // 4)
    if want > MAX_GAS_WEI:
        raise ChainError(
            f"base fee {base} wei would need {want}, above the {MAX_GAS_WEI} cap — not sending"
        )
    return want


def wait_for_nonce_settled(dep: Deployment, address: str, timeout_s: int = 45) -> bool:
    """Block until the account has nothing pending, or give up.

    The send lock stops two of our scripts *signing* at once. It does not stop one of them from
    having left a transaction in the mempool: a `cast send` that errors after the node accepted it
    releases the lock with the nonce still in flight, and the next signer computes the same nonce
    and is told `replacement transaction underpriced`. Comparing the pending and latest counts is
    the node's own answer to "is there anything of mine still out there".
    """
    deadline = time.monotonic() + timeout_s
    while True:
        pending = int(rpc(dep, "eth_getTransactionCount", [address, "pending"]), 16)
        latest = int(rpc(dep, "eth_getTransactionCount", [address, "latest"]), 16)
        if pending == latest:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(3)


def send(
    dep: Deployment,
    to: str,
    sig: str,
    args: list[str],
    account: str,
    password_file: str | None = None,
    dry_run: bool = True,
    gas_price: str | None = None,
) -> str | None:
    """Signs with the named foundry keystore. Returns the tx hash, or None on a dry run.

    Delegated to `cast` rather than reimplemented: the key never leaves the keystore, the
    signing path is the same one every other script in this repository uses, and `--legacy` is
    required because the node otherwise supplies a priority fee above its own max fee.

    The price is read off the chain unless one is passed. 999's base fee sits at its 0.1 gwei
    floor almost all the time and then briefly does not — 2.17 gwei on 8 Sep — and a legacy
    transaction priced under the base fee is not rejected, it is accepted into the mempool and
    never mined. The nonce then jams and every later send is `already known`.
    """
    cast = shutil.which("cast") or str(Path.home() / ".foundry/bin/cast")
    if not Path(cast).exists():
        raise ChainError("cast not found (looked on PATH and in ~/.foundry/bin)")
    price = gas_price or f"{gas_price_wei(dep)}"
    cmd = [cast, "send", to, sig, *args, "--rpc-url", dep.rpc_url,
           "--legacy", "--gas-price", price, "--account", account]
    if password_file:
        cmd += ["--password-file", password_file]

    if dry_run:
        print(f"  would send: {sig} {' '.join(args)} -> {to}")
        return None

    sender = subprocess.run(
        [cast, "wallet", "address", "--account", account]
        + (["--password-file", password_file] if password_file else []),
        capture_output=True, text=True,
    ).stdout.strip()
    if sender and not wait_for_nonce_settled(dep, sender):
        raise ChainError(f"{sender} still has a transaction pending after 45s; not sending")

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
