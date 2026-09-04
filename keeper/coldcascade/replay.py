"""Drives the live demo on an anvil fork of 999: plants HyperCoreMock at the precompile addresses
with anvil_setCode, walks the tape minute by minute, sets the mock book, and sends the arb and
flow takers through the official router. Same tape and same rules as test/Oct10Replay.t.sol, so
the numbers must agree."""

from pathlib import Path

from .chain import Deployment


def plant_hypercore_mock(dep: Deployment) -> None:
    raise NotImplementedError("todo")


def set_book(dep: Deployment, perp_index: int, bid: int, ask: int, mark: int, oracle: int) -> None:
    raise NotImplementedError("todo")


def run(dep: Deployment, tape_path: Path, speed: float, account: str) -> None:
    raise NotImplementedError("todo")
