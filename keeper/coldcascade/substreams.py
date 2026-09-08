"""The Graph side of the loop: a Substreams stream, read as a subprocess.

Why a subprocess and not a sink. A sink means Postgres, Docker and a schema migration, and none
of that would make the numbers better — the whole corpus is a few hundred fills. `substreams run`
already speaks newline-delimited JSON, and the module on the other end (`substreams/`) has done
the decoding. What is left here is a pipe and a parser.

Why Substreams and not a subgraph. Subgraph Studio reports `hyper-evm: subgraphsSupportLevel:
"none"` — there is no hosted subgraph for chain 999 to deploy to. The Graph Market for Substreams
is open on this chain and is the second qualifying provider named on the prize page. The endpoint
is Pinax's.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Iterator

ROOT = Path(__file__).resolve().parents[2]
SPKG = ROOT / "substreams" / "coldcascade-v0.1.0.spkg"
ENDPOINT = os.environ.get("SUBSTREAMS_ENDPOINT", "hyperevm.substreams.pinax.network:443")
MODULE = "desk_events"


class StreamError(RuntimeError):
    pass


def _binary() -> str:
    exe = shutil.which("substreams") or str(Path.home() / ".local/bin/substreams")
    if not Path(exe).exists():
        raise StreamError(
            "substreams not found on PATH or in ~/.local/bin — "
            "install from github.com/streamingfast/substreams/releases"
        )
    return exe


def _token() -> str:
    tok = os.environ.get("SUBSTREAMS_API_TOKEN") or os.environ.get("PINAX_JWT")
    if not tok:
        raise StreamError("no SUBSTREAMS_API_TOKEN and no PINAX_JWT in the environment")
    return tok


def stream(start_block: int, stop_block: int, spkg: Path | None = None) -> Iterator[dict]:
    """Yield one decoded `coldcascade.v1.DeskEvents` per block that had anything in it.

    Blocks with none of our four contracts never reach the module: `index_desk_events` writes a
    key per contract that spoke, and `desk_events` filters on it. A quarter of a million blocks
    of HyperEVM go past and seventeen come out.
    """
    spkg = spkg or SPKG
    if not spkg.exists():
        raise StreamError(f"no {spkg} — run `substreams pack substreams.yaml` in substreams/")

    env = dict(os.environ, SUBSTREAMS_API_TOKEN=_token())
    cmd = [
        _binary(), "run", "-e", ENDPOINT, str(spkg), MODULE,
        "-s", str(start_block), "-t", str(stop_block),
        "-o", "jsonl",
        # The guard is there to stop somebody accidentally scanning a mainnet from genesis. Our
        # range is a quarter of a million blocks and is the point of the exercise.
        "--limit-processed-blocks", "0",
    ]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    assert p.stdout is not None
    for line in p.stdout:
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if msg.get("@module") == MODULE:
            yield msg["@data"]
    p.wait()
    if p.returncode != 0:
        # Keep it. A swallowed auth failure here is indistinguishable from a desk nobody traded.
        raise StreamError(f"substreams run exited {p.returncode}: {(p.stderr.read() or '').strip()}")


# --- the cache --------------------------------------------------------------------------------

CACHE = ROOT / "keeper" / ".cache" / "desk_events.jsonl"

# Blocks this far behind the head are re-streamed on every run rather than trusted from cache.
# HyperEVM finalises fast, but a cache is a claim about history and the cheap way to keep that
# claim true is to stop making it about the last few minutes.
REORG_MARGIN_BLOCKS = 400


def cached_stream(start_block: int, stop_block: int, cache: Path | None = None) -> list[dict]:
    """The same blocks as `stream`, but only the new ones cross the network.

    A full scan is a quarter of a million blocks, four minutes and eighty megabytes of egress.
    Run on a twenty-minute cadence that is most of a day of traffic to re-derive a corpus that
    did not change. What did change is the tail, and the tail is what this re-reads.
    """
    cache = cache or CACHE
    kept: dict[int, dict] = {}
    if cache.exists():
        for line in cache.read_text().splitlines():
            if not line.strip():
                continue
            try:
                blk = json.loads(line)
            except json.JSONDecodeError:
                continue
            n = int(blk["blockNumber"])
            if start_block <= n <= stop_block:
                kept[n] = blk

    frontier = max(kept) if kept else start_block - 1
    resume = max(start_block, min(frontier + 1, stop_block - REORG_MARGIN_BLOCKS))
    for n in [n for n in kept if n >= resume]:
        del kept[n]

    if resume <= stop_block:
        print(f"  cache holds {len(kept)} blocks; streaming {resume} -> {stop_block}")
        for blk in stream(resume, stop_block):
            kept[int(blk["blockNumber"])] = blk

    cache.parent.mkdir(parents=True, exist_ok=True)
    ordered = [kept[n] for n in sorted(kept)]
    cache.write_text("".join(json.dumps(b, separators=(",", ":")) + "\n" for b in ordered))
    return ordered
