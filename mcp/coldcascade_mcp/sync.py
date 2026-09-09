"""The server's own way to the stream, and the corpus it ships with.

Every other module here reads a corpus somebody else fetched. This one goes and gets it, and it
exists because of what a clone looks like from outside this machine. `keeper/.cache/` is a local
working directory and is not in the repository, so a server that only ever read it would start
empty on anyone else's computer: `describe_coverage` would report zero observations and every
`get_book_at_time` would answer `beforeSeries`. The stream would be real and unreachable.

Two things close that, and they are deliberately different in kind:

  * **`results/desk-events.jsonl`** is a committed snapshot of the decoded corpus. It makes the
    server answer on a fresh clone with no credentials, no binary and no network, and every
    response says it is a snapshot and which block it stops at. It is a floor, not the source.
  * **`sync_stream`** runs the keeper's own `cached_stream` — imported from
    `keeper/coldcascade/substreams.py`, the same function the twenty-minute cadence calls, not a
    copy of it — against Pinax through The Graph Market. It seeds the cache from the snapshot
    first, so the first call on a clone streams the tail rather than a quarter of a million
    blocks, and it reports how many blocks crossed the network and from which endpoint.

The one thing this module must not become is a way to answer a book query from a node. The only
RPC in the whole server is the `eth_blockNumber` below, and it asks *where to stop*, not what the
book was. Where to stop is ordinary chain state; the book at a past block is the thing no node
has, which is the entire reason the archive exists.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import shutil
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KEEPER = ROOT / "keeper" / "coldcascade"
SNAPSHOT = ROOT / "results" / "desk-events.jsonl"
LIVE = ROOT / "keeper" / ".cache" / "desk_events.jsonl"

TOKEN_VARS = ("SUBSTREAMS_API_TOKEN", "PINAX_JWT")
MARKET_URL = "https://thegraph.market"


class SyncError(RuntimeError):
    pass


def _keeper(name: str):
    """Import one keeper module by path, without importing the keeper package.

    By path because the two trees are separate on purpose: the MCP server is standard library
    only and installs with nothing, and `import coldcascade` would drag in the keeper's package
    layout and its pyproject. Both files this reaches are themselves standard library only, so
    loading them costs nothing and — the point — the streaming code the judge runs is byte for
    byte the code the cadence runs, rather than a second implementation that can drift from it.
    """
    path = KEEPER / f"{name}.py"
    if not path.exists():
        raise SyncError(f"no {path.relative_to(ROOT)} — the keeper is not in this checkout")
    key = f"_coldcascade_keeper_{name}"
    if key in sys.modules:
        return sys.modules[key]
    spec = importlib.util.spec_from_file_location(key, path)
    mod = importlib.util.module_from_spec(spec)
    # Registered *before* it is executed, and not optional: `chain.py` defines a frozen dataclass,
    # and `@dataclass` resolves its own annotations through `sys.modules[cls.__module__]`. A module
    # that is absent from there raises `'NoneType' object has no attribute '__dict__'` at import,
    # which reads like a bug in this file rather than a missing registration.
    sys.modules[key] = mod
    try:
        spec.loader.exec_module(mod)
    except Exception:
        del sys.modules[key]
        raise
    return mod


def _corpus_extent(path: Path) -> dict:
    """Blocks and the last one, read cheaply — the file is newline-delimited per block."""
    if not path.exists():
        return {"blocks": 0, "lastBlock": None}
    blocks, last = 0, None
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        blocks += 1
        i = line.find('"blockNumber":')
        if i >= 0:
            last = int(line[i + 14:].split(",")[0].strip().strip('"'))
    return {"blocks": blocks, "lastBlock": last}


def readiness() -> dict:
    """What is missing before a sync can happen, named one by one rather than as a failure."""
    binary = shutil.which("substreams") or (
        str(Path.home() / ".local/bin/substreams")
        if (Path.home() / ".local/bin/substreams").exists() else None
    )
    token = next((v for v in TOKEN_VARS if os.environ.get(v)), None)
    spkg = next(iter(sorted((ROOT / "substreams").glob("*.spkg"))), None)
    missing = []
    if not binary:
        missing.append(
            "the `substreams` CLI is not on PATH — install it from "
            "github.com/streamingfast/substreams/releases"
        )
    if not token:
        missing.append(
            f"neither SUBSTREAMS_API_TOKEN nor PINAX_JWT is set — a free key from {MARKET_URL} "
            "(The Graph Market) authenticates the Pinax endpoint this package streams from"
        )
    if spkg is None:
        missing.append("no .spkg in substreams/ — run `substreams pack substreams.yaml` there")
    return {"ready": not missing, "missing": missing,
            "binary": binary, "tokenVariable": token,
            "package": str(spkg.relative_to(ROOT)) if spkg else None}


def sync(*, from_block: int | None = None, to_block: int | None = None) -> dict:
    """Stream from the provider into the corpus this server serves, and say what moved.

    Returns a result in every case, including the case where nothing can be streamed: a judge
    who has not got a key should be told what to get and where, and told what is being served
    meanwhile, rather than handed an exception that looks like a broken tool.
    """
    ready = readiness()
    before = _corpus_extent(LIVE if LIVE.exists() else SNAPSHOT)

    if not ready["ready"]:
        return {
            "status": "notConfigured",
            "missing": ready["missing"],
            "servingMeanwhile": {
                "corpus": "snapshot" if not LIVE.exists() else "live",
                **before,
                "note": (
                    "The committed snapshot answers every tool with no credentials at all. It is "
                    "a floor: it stops at the block above and nothing after that block is in it."
                ),
            },
            "howToConfigure": [
                f"Get a free Substreams key at {MARKET_URL}.",
                "export SUBSTREAMS_API_TOKEN=<the key>",
                "Install the CLI: github.com/streamingfast/substreams/releases",
                "Call sync_stream again.",
            ],
        }

    substreams = _keeper("substreams")
    chain = _keeper("chain")
    dep = chain.load_deployment(999)

    # Seed the cache from the committed snapshot before streaming. Without this the first call on
    # a clone re-streams from the deployment block — a quarter of a million HyperEVM blocks and
    # about four minutes — to rebuild a corpus that is already sitting in the checkout.
    seeded = False
    if not LIVE.exists() and SNAPSHOT.exists():
        LIVE.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SNAPSHOT, LIVE)
        seeded = True

    start = int(from_block) if from_block is not None else int(dep.deployed_at_block)
    if to_block is not None:
        head = int(to_block)
    else:
        # The only node call in this server. `eth_blockNumber` is where to stop; it is not, and
        # must never become, a way to answer what the book was.
        head = int(chain.rpc(dep, "eth_blockNumber", []), 16)

    t0 = time.time()
    # The keeper prints its progress to stdout, which here is the JSON-RPC channel: one stray line
    # and the client's parser dies mid-session on what looks like a protocol error. Captured rather
    # than silenced, because "cache holds 1469 blocks; streaming 45440786 -> 45441902" is precisely
    # the line that shows only the tail crossed the network, and it belongs in the answer.
    log = io.StringIO()
    try:
        with contextlib.redirect_stdout(log):
            blocks = substreams.cached_stream(start, head)
    except substreams.StreamError as e:
        # Never swallowed. An auth failure that reads as "no new blocks" is indistinguishable
        # from a desk nobody traded, and this tool exists to prove the stream is reachable.
        return {
            "status": "streamFailed",
            "error": str(e),
            "providerLog": [ln for ln in log.getvalue().splitlines() if ln.strip()],
            "endpoint": substreams.ENDPOINT,
            "package": str(substreams.SPKG.relative_to(ROOT)),
            "servingMeanwhile": {**before, "corpus": "live" if LIVE.exists() else "snapshot"},
        }
    elapsed = round(time.time() - t0, 1)

    after = _corpus_extent(LIVE)
    counts = {"books": 0, "fills": 0, "markouts": 0}
    for b in blocks:
        for k in counts:
            counts[k] += len(b.get(k) or [])

    # What actually crossed the network: `cached_stream` resumes at the cached frontier pulled back
    # by the reorg margin, so the range below is the range the provider was asked for, and it is
    # reported separately from the net change in the corpus. Those two are different numbers and
    # conflating them would let a busy re-read look like new data, or a quiet one look like a
    # stream that did nothing.
    frontier = before["lastBlock"] or (start - 1)
    resume = max(start, min(frontier + 1, head - substreams.REORG_MARGIN_BLOCKS))

    return {
        "status": "synced",
        "provider": "The Graph Market for Substreams",
        "endpoint": substreams.ENDPOINT,
        "package": str(substreams.SPKG.relative_to(ROOT)),
        "module": substreams.MODULE,
        "requested": {"fromBlock": start, "toBlock": head, "blocksSpanned": head - start},
        "streamedFromNetwork": {
            "fromBlock": resume,
            "toBlock": head,
            "blocksScanned": max(head - resume + 1, 0),
            "netNewBlocksWithEvents": after["blocks"] - before["blocks"],
            "seededFromSnapshot": seeded,
            "reorgMarginBlocks": substreams.REORG_MARGIN_BLOCKS,
            "note": (
                "Only blocks past the cached frontier, less the reorg margin, crossed the "
                "network; the rest were already decoded. A cache is a claim about history, and "
                "the cheap way to keep it true is to stop making it about the last few minutes. "
                "So the last few hundred blocks are re-read every time and a net zero means the "
                "corpus was already current, not that nothing was streamed."
            ),
        },
        "corpusNow": {"corpus": "live", "path": str(LIVE.relative_to(ROOT)), **after,
                      "decodedEvents": counts},
        "secondsElapsed": elapsed,
        "providerLog": [ln for ln in log.getvalue().splitlines() if ln.strip()],
        "reproduce": (
            f"substreams run -e {substreams.ENDPOINT} "
            f"{substreams.SPKG.relative_to(ROOT)} {substreams.MODULE} "
            f"-s {start} -t {head} -o jsonl --limit-processed-blocks 0"
        ),
    }
