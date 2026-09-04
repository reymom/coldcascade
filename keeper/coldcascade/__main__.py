"""coldcascade tape | map | poke | markouts | replay | plot"""

import argparse
import sys
from pathlib import Path

from . import tape as tape_mod

ROOT = Path(__file__).resolve().parents[2]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="coldcascade")
    sub = parser.add_subparsers(dest="command", required=True)

    t = sub.add_parser("tape", help="rebuild the Oct-10 tape")
    t.add_argument(
        "--stub",
        action="store_true",
        help="real Coinbase spot with a synthetic book and forced flow over it, "
        "cut to carry the full markout tail",
    )
    t.add_argument("--out", type=Path, default=ROOT / "tape" / "oct10_btc_1m.stub.json")
    t.add_argument("--cache", type=Path, default=ROOT / "tape" / ".cache")

    for name in ("map", "poke", "markouts", "replay", "plot"):
        sub.add_parser(name)

    args = parser.parse_args(argv)

    if args.command == "tape":
        if not args.stub:
            raise NotImplementedError("todo: the real tape needs the S3 fill log")
        minutes = tape_mod.build_stub_tape(args.cache, args.out)
        last = tape_mod.last_forced_minute(minutes)
        print(
            f"{args.out}: {len(minutes)} minutes, "
            f"last forced at {last}, {len(minutes) - 1 - last} of tail"
        )
        return 0

    raise NotImplementedError(f"todo: {args.command}")


if __name__ == "__main__":
    sys.exit(main())
