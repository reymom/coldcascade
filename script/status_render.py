"""The screen. Reads what status.sh gathered and says whether anything is wrong.

Every line is a tick or a cross and a sentence you can act on. Nothing here reaches the network:
the reads already happened, in parallel, and an empty file means that read failed — which prints
as `unreadable`, never as a zero. A number you cannot obtain and a number that is zero are
different facts, and conflating them is how a healthy poster got reported as empty.
"""

from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CFG = Path.home() / ".config" / "coldcascade"

# Burn rates, HYPE per day, measured on 9 Sep after the poke moved to its own box and its own key.
# They are estimates and the margin they produce is an estimate; what is exact is the balance.
BURN = {"poker": 0.015, "taker": 0.011, "poster": 0.001, "operator": 0.001}

# What the runway has to cover: the end of the live finalist round, not the submission deadline.
DEADLINE = datetime(2026, 9, 14, 20, 0, tzinfo=timezone(timedelta(hours=2)))

# BTC on Hyperliquid: perp index 0, szDecimals 5, max leverage 40 -> maintenance margin 1/80.
SZ_DECIMALS, MAX_LEVERAGE = 5, 40
MM = 1 / (2 * MAX_LEVERAGE)

FAILED: list[str] = []
UNKNOWN: list[str] = []
BRIEF: dict[str, str] = {}      # the one-line summary, assembled where the numbers already are


def read(d: Path, name: str) -> str | None:
    p = d / name
    if not p.exists():
        return None
    v = p.read_text().strip()
    return v or None


def word(hexstr: str, i: int) -> int:
    s = hexstr[2:] if hexstr.startswith("0x") else hexstr
    return int(s[i * 64:(i + 1) * 64], 16)


def i64(x: int) -> int:
    return x - (1 << 256) if x >= (1 << 255) else x


def ago(seconds: float) -> str:
    s = int(seconds)
    if s < 0:
        return "in the future"
    if s < 90:
        return f"{s}s ago"
    if s < 5400:
        return f"{s // 60}m ago"
    if s < 172800:
        return f"{s // 3600}h {(s % 3600) // 60}m ago"
    return f"{s // 86400}d {(s % 86400) // 3600}h ago"


def line(ok: bool | None, label: str, text: str) -> None:
    """ok=None means the check could not be made at all, which is neither pass nor fail — and is
    counted separately, because a tool that reports "all green" for checks it never managed to run
    is worse than no tool. Silence about a thing is not evidence about it."""
    mark = "?" if ok is None else ("\u2713" if ok else "\u2717")
    if ok is None:
        UNKNOWN.append(label.strip())
    if ok is False:
        FAILED.append(label.strip())
    print(f"  {mark} {label:<9} {text}".rstrip())


def last_log(path: Path, needle: str | None = None) -> tuple[float, str] | None:
    """(unix seconds, the line) of the most recent entry, optionally matching a marker."""
    try:
        rows = [r for r in path.read_text().splitlines() if r.strip() and not r.startswith("\t")]
    except OSError:
        return None
    for row in reversed(rows):
        if needle and needle not in row:
            continue
        stamp = row.split("\t")[0].split("  ")[0].strip()
        try:
            t = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        except ValueError:
            continue
        if t.tzinfo is None:
            t = t.replace(tzinfo=timezone.utc)
        return t.timestamp(), row
    return None


def main() -> int:
    # `--brief` prints the same state as one line. The monitor uses it, so the wording of "healthy"
    # lives here and cannot drift from what the full screen says.
    brief = "--brief" in sys.argv
    argv = [a for a in sys.argv if a != "--brief"]
    if brief:
        sys.stdout = open(os.devnull, "w")
    d = Path(argv[1])
    hedged, opdesk, operator = argv[2], argv[3], (argv[4] if len(argv) > 4 else "")
    now = time.time()

    head = read(d, "head")
    print()
    print(f"coldcascade  {datetime.now().strftime('%a %d %b %H:%M')}"
          f"        chain 999 · head {head or 'unreadable'}")
    print()

    # 1 --- the four cadences ------------------------------------------------------------------
    print("CADENCES")
    poked = read(d, "poked")
    if poked is None:
        line(None, "poke", "pokedAt(0) unreadable on both endpoints — a read failure, not a stall")
    else:
        age = now - int(poked.split()[0])
        # 25 minutes, not 15: the cadence thins as gas rises (EVERY = price / 0.25 gwei), so a
        # long interval during a spike is the rule working rather than a failure.
        line(age < 1500, "poke", f"hetzner   last {ago(age):<12} pokedAt(0) on chain")
        BRIEF["poke"] = f"poke {ago(age)}"

    for label, path, needle, limit, extra in (
        ("fills",  CFG / "cadence.log",  "\tOK\t", 2700, None),
        ("keeper", CFG / "markout.log",  "\tOK\t", 2400, None),
        ("cover",  CFG / "cover.log",    None,      900, "state"),
    ):
        got = last_log(path, needle)
        if got is None:
            line(None, label, f"{path} unreadable or empty")
            continue
        t, row = got
        age = now - t
        tail = ""
        if extra == "state":
            tail = "square" if "SQUARE" in row else row.split("\t")[-1][:38]
        line(age < limit, label, f"laptop    last {ago(age):<12} {tail}")
        BRIEF[label] = f"{label} {ago(age)}"
    print()

    # 2 --- is the page serving what the keeper computed? --------------------------------------
    print("PAGE")
    local = deployed = None
    try:
        local = json.loads((ROOT / "results" / "markouts.json").read_text())["generatedAt"]
    except Exception:
        pass
    try:
        deployed = json.loads((d / "deployed.json").read_text())["generatedAt"]
    except Exception:
        pass
    if local is None or deployed is None:
        which = "on disk" if local is None else "at coldcascade.vercel.app"
        line(None, "artifact", f"unreadable {which}")
    else:
        lag = local - deployed
        # The keeper rewrites the artifact every twenty minutes and only a hand-run publish moves
        # the deployed copy, so *some* lag is the normal resting state and not a fault. The first
        # version failed the whole screen above twenty minutes, which meant it went red within one
        # keeper pass of every publish and stayed red — an alarm that is always on is an alarm
        # nobody reads. Six hours is where the page stops being a fair picture of the desk.
        #
        # The hint prints from the first minute of drift either way: knowing there is something to
        # run is useful long before it becomes a problem.
        stale = lag > 6 * 3600
        if lag <= 60:
            line(True, "artifact", "deployed copy is current")
            BRIEF["page"] = "page current"
        else:
            behind = ago(lag).replace(" ago", "")
            line(not stale, "artifact", f"deployed copy is {behind} behind disk"
                 + ("" if stale else "  (fine; publish when convenient)"))
            BRIEF["page"] = f"page {behind} behind"
            print("               -> ./script/publish-results.sh")
    print()

    # 3 --- balances, and how long each lasts --------------------------------------------------
    days_needed = max(0.0, (DEADLINE.timestamp() - now) / 86400)
    print(f"BALANCES                                        {days_needed:.1f} days to Mon 14th 20:00")
    op_read_failed = (d / "op").exists() and not (d / "op").read_text().strip()
    disarmed = (not op_read_failed) and (
        not operator or operator.lower() == "0x" + "0" * 40)
    for label in ("poker", "taker", "poster", "operator"):
        raw = read(d, f"bal.{label}")
        if raw is None:
            why = ("the operator desk reports no armed operator"
                   if label == "operator" and disarmed else
                   "hedgeOperator() unreadable, so the balance was not looked up"
                   if label == "operator" and op_read_failed else
                   "balance unreadable on both endpoints")
            line(None, label, why)
            continue
        hype = int(raw.split()[0]) / 1e18
        rate = BURN[label]
        days = hype / rate if rate else float("inf")
        if label == "poker":
            BRIEF["poker"] = f"poker {hype:.4f} HYPE ({days:.1f}d)"
        note = "" if label != "operator" else ("   DESK NOT ARMED" if disarmed else "   armed")
        line(days >= days_needed, label,
             f"{hype:8.4f} HYPE   ~{days:5.1f} days at {rate:.3f}/day{note}")
    print()

    # 4 --- the two shorts ---------------------------------------------------------------------
    print("SHORTS")
    mark_raw = read(d, "mark")
    mark = None
    if mark_raw:
        try:
            mark = int(mark_raw, 16) if mark_raw.startswith("0x") else int(mark_raw)
        except ValueError:
            mark = None
    for label, desk in (("hedged", hedged), ("operator", opdesk)):
        pos, mrg = read(d, f"pos.{desk}"), read(d, f"mrg.{desk}")
        if pos is None or mrg is None or mark is None:
            line(None, label, "position, margin or mark unreadable")
            continue
        szi = i64(word(pos, 0))
        if szi == 0:
            line(True, label, f"{desk[:10]}  no open position")
            continue
        size = abs(szi) / 10 ** SZ_DECIMALS
        px = mark / 10 ** (6 - SZ_DECIMALS)
        av = word(mrg, 0) / 1e6
        # Cross margin, one position: liquidation is where equity meets maintenance margin.
        #   AV0 - size*(P - P0) = size*P*MM   ->   P = (AV0 + size*P0) / (size*(1 + MM))
        # The desks hold exactly one position each, which is what makes this exact rather than
        # indicative; if a second one is ever opened this number stops being right.
        liq = (av + size * px) / (size * (1 + MM))
        head_pct = (liq - px) / px * 100
        line(head_pct > 10, label,
             f"{desk[:10]}  {size:.5f} BTC short  liq ${liq:,.0f}  BTC +{head_pct:.1f}%")
    print()

    # 5 --- the corpus -------------------------------------------------------------------------
    print("CORPUS")
    try:
        m = json.loads((ROOT / "results" / "markouts.json").read_text())
        s = m["summary"]
        fills, complete, span = s["fills"], s["fillsWithCompleteHorizons"], s["spanDays"]
        line(True, "fills", f"{fills} fills over {span} days · {complete} with a complete 5/15/60")
        BRIEF["corpus"] = f"{fills} fills / {complete} complete"
    except Exception:
        line(None, "fills", "results/markouts.json unreadable")
    try:
        a = json.loads((ROOT / "results" / "book-archive.json").read_text())
        ts = [o["t"] for o in a["observations"]]
        gaps = [b - x for x, b in zip(ts, ts[1:])]
        worst = max(gaps) if gaps else 0
        med = sorted(gaps)[len(gaps) // 2] if gaps else 0
        line(worst < 1800, "books",
             f"{a['count']} observations · {med}s median gap · {worst}s worst")
    except Exception:
        line(None, "books", "results/book-archive.json unreadable")
    print()

    if brief:
        sys.stdout.close(); sys.stdout = sys.__stdout__
        bits = " · ".join(BRIEF.get(k, f"{k}?")
                          for k in ("poke", "cover", "page", "poker", "corpus"))
        verdict = ("NOT HEALTHY: " + ", ".join(FAILED)) if FAILED else (
                  ("NOT VERIFIED: " + ", ".join(UNKNOWN)) if UNKNOWN else "all green")
        print(f"{verdict} — {bits}")
        return 1 if FAILED else (2 if UNKNOWN else 0)

    if FAILED:
        extra = f"; {len(UNKNOWN)} not checked" if UNKNOWN else ""
        print(f"NOT HEALTHY — {', '.join(FAILED)}{extra}")
        return 1
    if UNKNOWN:
        print(f"NOT VERIFIED — could not check: {', '.join(UNKNOWN)}")
        print("               nothing is known to be broken, but nothing above is confirmed either")
        return 2
    print("all green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
