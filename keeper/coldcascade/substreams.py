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
