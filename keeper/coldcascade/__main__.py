"""coldcascade tape | map | poke | markouts | tolls | replay | plot"""

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

    m = sub.add_parser(
        "markouts",
        help="stream fills and books off Substreams, join them, post to MarkoutLedger",
    )
    m.add_argument("--chain-id", type=int, default=999)
    m.add_argument("--start-block", type=int, default=None, help="default: deployedAtBlock")
    m.add_argument("--stop-block", type=int, default=None, help="default: the head")
    m.add_argument("--out", type=Path, default=ROOT / "results" / "markouts.json")
    m.add_argument("--account", default="coldcascade-deployer", help="foundry keystore name")
    m.add_argument("--password-file", default=None)
    m.add_argument("--limit", type=int, default=None, help="post at most this many")
    # Posting is the half that writes to the chain, so it is the half you ask for. A bare run
    # streams, joins, and writes results/markouts.json without sending anything.
    m.add_argument("--post", action="store_true", help="actually send; otherwise a dry run")

    # The counterfactual block of results/markouts.json, rebuilt off the artifacts already on
    # disk. The markouts run computes it inline; this recomputes it with no node, no key and no
    # network, which is what makes the cadence a parameter a reader can change rather than a
    # number they have to take on trust.
    tl = sub.add_parser("tolls", help="rebuild the counterfactual tolls in results/markouts.json")
    tl.add_argument("--markouts", type=Path, default=ROOT / "results" / "markouts.json")
    tl.add_argument("--archive", type=Path, default=ROOT / "results" / "book-archive.json")
    tl.add_argument("--events", type=Path, default=ROOT / "results" / "desk-events.jsonl")

    for name in ("map", "poke", "replay", "plot"):
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

    if args.command == "markouts":
        from . import markouts as markouts_mod
        from .chain import load_deployment

        dep = load_deployment(args.chain_id)
        doc = markouts_mod.run(
            dep,
            account=args.account,
            password_file=args.password_file,
            start_block=args.start_block,
            stop_block=args.stop_block,
            out=args.out,
            dry_run=not args.post,
            limit=args.limit,
        )
        s = doc["summary"]
        print(
            f"{s['fills']} fills over {s['spanDays']} days, "
            f"{s['fillsWithCompleteHorizons']} with a complete 5/15/60"
        )
        for h in doc["horizonsMinutes"]:
            st = s["byHorizon"][str(h)]
            if st["n"]:
                print(f"  {h:>2}m  n={st['n']:<4} mean {st['meanBps']:+.2f} bps  "
                      f"median {st['medianBps']:+.2f}  worst {st['minBps']:+.2f}")
            else:
                print(f"  {h:>2}m  no fill yet has a book that close to it")
        return 0

    if args.command == "tolls":
        from . import tolls as tolls_mod

        doc = tolls_mod.apply_to_artifact(args.markouts, args.archive, args.events)
        cf = doc["counterfactuals"]
        print(f"{args.markouts}: {cf['over']['fills']} fills, {cf['over']['rule']}")
        for name, line in cf["lines"].items():
            print(f"  {name:<13} ${line['tollUsd']:>10,.2f}  over {line['priced']} priced, "
                  f"{line['paying']} paying")
        print("  cadence sweep, oracle-pegged:")
        for row in cf["cadenceSweep"]:
            print(f"    {row['name']:<32} band {str(row['bandBps']):<24} "
                  f"{row['refreshes']:>5} refreshes  ${row['tollUsd']:>9,.2f}")
        return 0

    raise NotImplementedError(f"todo: {args.command}")


if __name__ == "__main__":
    sys.exit(main())
