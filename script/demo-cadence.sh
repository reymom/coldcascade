#!/usr/bin/env bash
# Demo-desk fill cadence: one take, varied side and size, against the mock pair.
#
# What this is, plainly: the demo desk trades tokens anyone can mint, and on a chain with no
# organic Aqua flow it would otherwise sit at two fills forever. This sends takes on a schedule so
# the desk has a working history to read — a soak test of the quote path against a book that keeps
# moving, and the demo data behind the console. The fills are real transactions through 1inch's
# deployed router at real prices; what is synthetic is the *demand*, which is this script.
#
# It will only ever touch `.demoDesk`. The canonical and hedged desks hold real inventory and a live
# short, and the guard below refuses them by address rather than by convention.
#
#   ./script/demo-cadence.sh              # one cycle: quote, mint, approve, swap
#   DRY_RUN=1 ./script/demo-cadence.sh    # decide and print, send nothing
#   JITTER_MAX_SEC=0 ./script/demo-cadence.sh
#
# Cycle cost is ~262k gas over three sends (mint 34k, approve 46k, swap 182k), pinned by
# Swap.s.sol to 0.15 gwei legacy: 3.9e-5 HYPE a cycle, measured on 999 on 8 Sep.
set -euo pipefail
cd "$(dirname "$0")/.."

# Foundry is in ~/.foundry/bin and cron's PATH has none of it. This is the difference between the
# job working and the log holding one "forge: not found" every three hours.
command -v forge >/dev/null || PATH="$HOME/.foundry/bin:$PATH"
command -v forge >/dev/null || { echo "forge not found (looked in ~/.foundry/bin)" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

[ -f .env ] && { set -a; . ./.env; set +a; }

RPC="${HYPEREVM_RPC_URL:-https://rpc.hyperliquid.xyz/evm}"
ACCOUNT="${TAKER_ACCOUNT:-coldcascade-taker}"
PASSFILE="${TAKER_PASSFILE:-$HOME/.config/coldcascade/taker.pass}"
LOG="${CADENCE_LOG:-$HOME/.config/coldcascade/cadence.log}"
# Cron fires on the interval; a take does not have to. Kept below the 20-minute interval with
# room to spare, so a jittered run cannot still be sleeping when the next one starts.
JITTER_MAX_SEC="${JITTER_MAX_SEC:-900}"
DRIFT_BAND_BPS="${DRIFT_BAND_BPS:-150}"    # beyond this the side is chosen to walk the pool back
DRY_RUN="${DRY_RUN:-0}"

FILE="deployments/999.json"
[ -f "$FILE" ] || { echo "no $FILE" >&2; exit 1; }

DEMO=$(jq -r '.demoDesk' "$FILE")
DESK="${DESK:-$DEMO}"
# The whole point of the guard: the two desks that must never see a scripted take, by address.
CANON=$(jq -r '.canonicalDesk' "$FILE"); HEDGED=$(jq -r '.hedgedDesk' "$FILE")
lc() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
if [ "$(lc "$DESK")" != "$(lc "$DEMO")" ]; then
  echo "refusing: DESK=$DESK is not the demo desk ($DEMO)." >&2
  [ "$(lc "$DESK")" = "$(lc "$CANON")" ] && echo "  that is the canonical desk — real inventory." >&2
  [ "$(lc "$DESK")" = "$(lc "$HEDGED")" ] && echo "  that is the hedged desk — open short, do not disturb." >&2
  exit 1
fi

TAKER=$(cast wallet address --account "$ACCOUNT" --password-file "$PASSFILE")
AUTH="--account $ACCOUNT --password-file $PASSFILE"

BAL=$(cast balance "$TAKER" --rpc-url "$RPC")
# One cycle at a pessimistic 0.5 gwei is 1.46e14 wei. Stop with a cycle's headroom left rather
# than dying between the approve and the swap. A dry run reports the balance and carries on, so
# the side and size it would have picked are visible before the key has ever been funded.
FLOOR=300000000000000
if [ "$BAL" -lt "$FLOOR" ] && [ "$DRY_RUN" != "1" ]; then
  printf '%s\tSKIP\tout of gas: %s wei left, floor %s\n' "$(date -Is)" "$BAL" "$FLOOR" >>"$LOG"
  echo "taker $TAKER has $BAL wei, below the $FLOOR floor — not sending." >&2
  exit 2
fi
[ "$BAL" -lt "$FLOOR" ] && echo "note: taker holds $BAL wei, below the $FLOOR floor — a real run would stop here." >&2

# --- what the pool looks like now, and which way it needs to go ------------------------------
read -r BASE QUOTE PERP PXNUM PXDEN < <(
  cast call "$DESK" 'params()((address,address,uint32,uint64,uint64,uint16,uint16,uint16,address,uint32,uint128,uint128,uint128))' \
    --rpc-url "$RPC" | python3 -c "
import sys,re
f=[re.sub(r'\s*\[.*','',x).strip() for x in sys.stdin.read().strip().lstrip('(').rstrip(')').split(',')]
print(f[0],f[1],f[2],f[3],f[4])"
)
BASEBAL=$(cast call "$BASE" 'balanceOf(address)(uint256)' "$DESK" --rpc-url "$RPC" | awk '{print $1}')
QUOTEBAL=$(cast call "$QUOTE" 'balanceOf(address)(uint256)' "$DESK" --rpc-url "$RPC" | awk '{print $1}')
ORACLE=$(cast to-dec "$(cast call "$(printf '0x%040x' 0x807)" "$(cast abi-encode 'f(uint32)' "$PERP")" --rpc-url "$RPC")")

# Side, then size. Inside the band the side is a coin flip, which is what keeps the sequence from
# reading as a sweep; outside it the side is forced, because minBase/maxBase are wide open on this
# desk and nothing else stops a week of one-way takes from walking the curve off the book.
read -r SELL_BASE AMOUNT DEVBPS < <(
python3 - "$BASEBAL" "$QUOTEBAL" "$ORACLE" "$PXNUM" "$PXDEN" "$DRIFT_BAND_BPS" <<'PY'
import sys, secrets
base, quote, oracle, pxnum, pxden, band = (int(x) for x in sys.argv[1:7])
l1 = oracle * pxnum / pxden                     # raw quote units per raw base unit
dev = (quote / base / l1 - 1) * 10_000          # pool against the book, in bps
if dev > band:      sell = True                 # too much quote: sell base in to walk it down
elif dev < -band:   sell = False
else:               sell = secrets.randbelow(2) == 0
# Log-uniform so most takes are small and a few are not, which is the shape real flow has.
lo, hi = (250_000, 3_500_000) if sell else (200_000_000, 3_000_000_000)
u = secrets.randbelow(10**9) / 10**9
amt = int(lo * (hi / lo) ** u)
print('true' if sell else 'false', amt, round(dev, 1))
PY
)

echo "desk $DESK · taker $TAKER · pool ${DEVBPS}bps off L1 · sell_base=$SELL_BASE · amount=$AMOUNT"

if [ "$DRY_RUN" = "1" ]; then
  echo "DRY_RUN=1 — nothing sent."
  exit 0
fi

# Cron fires on a schedule; a desk does not get taken on one. Sleep a random slice of the interval
# before touching the chain so the timestamps are irregular.
if [ "$JITTER_MAX_SEC" -gt 0 ]; then
  J=$(( RANDOM * RANDOM % JITTER_MAX_SEC ))
  echo "jitter ${J}s"; sleep "$J"
fi

# The poke cadence signs from a key that may be this one, and HyperEVM rejects a nonce ahead of
# the account rather than queueing it — two of our own scripts sending at once is a lost
# transaction, not a delay. Taken after the jitter sleep, so a 40-minute wait here is not a
# 40-minute hole in the book series.
# A fixed path, not $XDG_RUNTIME_DIR: cron has no XDG_RUNTIME_DIR and a login shell does, so a
# variable one is two different locks and no exclusion at all between the cron job and a hand run.
exec 9>"$HOME/.config/coldcascade/send.lock"
flock -w 300 9 || { echo "could not take the send lock in 300s" >&2; exit 3; }

# firstswap.sh is the only path that sends: it re-derives the calldata from Swap.s.sol every run,
# so the order bytes are always the ones the account actually holds. Keep its stderr — a swallowed
# rate-limit here reads in the log as a desk nobody wanted to take.
OUT=$(DESK="$DESK" SELL_BASE="$SELL_BASE" AMOUNT="$AMOUNT" TAKER="$TAKER" CAST_AUTH="$AUTH" \
        ./script/firstswap.sh 2>&1) || STATUS=$? ; STATUS="${STATUS:-0}"
printf '%s\n' "$OUT"

HASH=$(printf '%s' "$OUT" | awk '/^swap 0x/ { print $2 }')
if [ "$STATUS" != "0" ] || [ -z "$HASH" ]; then
  { printf '%s\tFAIL\tsell_base=%s\tamount=%s\tdev=%s\texit=%s\n' \
      "$(date -Is)" "$SELL_BASE" "$AMOUNT" "$DEVBPS" "$STATUS"
    printf '%s\n' "$OUT" | sed 's/^/\t/'; } >>"$LOG"
  exit "${STATUS:-1}"
fi

GAS=$(cast receipt "$HASH" --rpc-url "$RPC" 2>/dev/null | awk '/^gasUsed/ { print $2 }')
printf '%s\tOK\tsell_base=%s\tamount=%s\tdev=%s\tgas=%s\t%s\n' \
  "$(date -Is)" "$SELL_BASE" "$AMOUNT" "$DEVBPS" "${GAS:-?}" "$HASH" >>"$LOG"
