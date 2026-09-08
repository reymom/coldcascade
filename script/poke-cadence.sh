#!/usr/bin/env bash
# One poke of BookCache, on a cadence, so the book series exists at all.
#
# Why this has to run: the HyperCore precompiles ignore the block tag (results/999_precompile_
# block_tag.md). An eth_call pinned 200 000 blocks back answers with the *current* book, so there
# is no archive read and no way to ask what the book was five minutes ago. The only way that
# quantity exists is for somebody to have written the words into a log while they were current.
# `BookCache.poke` is that somebody, it is permissionless, and until 8 Sep nobody had ever called
# it on mainnet — `pokedAt(0)` was 0 and there was not one `Booked` event on chain 999. A markout
# is a Fill joined to a later Booked, so with no Booked the join has no right-hand side and the
# keeper has nothing to compute.
#
#   ./script/poke-cadence.sh              # one poke of perp 0
#   DRY_RUN=1 ./script/poke-cadence.sh    # decide and print, send nothing
#   PERP=0 POKE_ACCOUNT=… POKE_PASSFILE=… ./script/poke-cadence.sh
#
# Warm cost is ~51k gas; the first poke of a perp is ~85k because every slot it writes is cold.
set -euo pipefail
cd "$(dirname "$0")/.."

# Same trap as demo-cadence.sh: cron's PATH has no forge and no cast.
command -v cast >/dev/null || PATH="$HOME/.foundry/bin:$PATH"
command -v cast >/dev/null || { echo "cast not found (looked in ~/.foundry/bin)" >&2; exit 1; }
command -v jq   >/dev/null || { echo "jq not found" >&2; exit 1; }

[ -f .env ] && { set -a; . ./.env; set +a; }

RPC="${HYPEREVM_RPC_URL:-https://rpc.hyperliquid.xyz/evm}"
PERP="${PERP:-0}"
LOG="${POKE_LOG:-$HOME/.config/coldcascade/poke.log}"
DRY_RUN="${DRY_RUN:-0}"
GAS_PRICE="${POKE_GAS_PRICE:-0.15gwei}"     # base fee on 999 is a flat 0.1 gwei; this is the margin
ATTEMPTS="${POKE_ATTEMPTS:-3}"

# The poster pays if its password is on disk, the taker otherwise. Both work — poke() is
# permissionless by design, "the caller chooses when, never what" — but the poster is the account
# with a budget for five days of this, and the taker's gas is the fill cadence's fuel.
DEPLOYER_PASS="${POKE_PASSFILE:-$HOME/.config/coldcascade/deployer.pass}"
TAKER_PASS="$HOME/.config/coldcascade/taker.pass"
if [ -f "$DEPLOYER_PASS" ]; then
  ACCOUNT="${POKE_ACCOUNT:-${DEPLOYER_ACCOUNT:-coldcascade-deployer}}"; PASSFILE="$DEPLOYER_PASS"
elif [ -f "$TAKER_PASS" ]; then
  ACCOUNT="${POKE_ACCOUNT:-coldcascade-taker}"; PASSFILE="$TAKER_PASS"
else
  echo "no keystore password file for either account — nothing can sign" >&2; exit 1
fi

FILE="deployments/999.json"
[ -f "$FILE" ] || { echo "no $FILE" >&2; exit 1; }
BOOKCACHE=$(jq -r '.bookCache' "$FILE")

POKER=$(cast wallet address --account "$ACCOUNT" --password-file "$PASSFILE")
BAL=$(cast balance "$POKER" --rpc-url "$RPC")
# ~1000 warm pokes of headroom at the pinned price. Below it, stop rather than starve whatever
# else that account is for — on the taker, that is the fill cadence.
FLOOR=8000000000000
if [ "$BAL" -lt "$FLOOR" ]; then
  printf '%s\tSKIP\tperp=%s\tpoker=%s\tbalance=%s below floor %s\n' \
    "$(date -Is)" "$PERP" "$POKER" "$BAL" "$FLOOR" >>"$LOG"
  echo "poker $POKER has $BAL wei, below the $FLOOR floor — not sending." >&2
  exit 2
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "would poke perp $PERP on $BOOKCACHE as $POKER ($BAL wei) — nothing sent."
  exit 0
fi

# HyperEVM rejects a nonce ahead of the account rather than queueing it, so two of our own scripts
# sending at once from the same key is a lost transaction, not a delay. Both take this lock.
# A fixed path, not $XDG_RUNTIME_DIR: cron has no XDG_RUNTIME_DIR and a login shell does, so a
# variable one is two different locks and no exclusion at all between the cron job and a hand run.
exec 9>"$HOME/.config/coldcascade/send.lock"
flock -w 300 9 || { echo "could not take the send lock in 300s" >&2; exit 3; }

# `--legacy` is not cosmetic. Without it cast builds a 1559 transaction, sets maxFeePerGas from
# --gas-price, and takes maxPriorityFeePerGas from the node's own suggestion — which on 999 is
# sometimes above 0.15 gwei, and the node then rejects its own advice with
# "max priority fee per gas higher than max fee per gas". A legacy transaction has one number.
#
# And it retries: at one send a minute against a public RPC, a transient -32602 is a normal
# Tuesday. A book series with a hole in it is worth five seconds of sleep.
STATUS=1; OUT=""
for i in $(seq 1 "$ATTEMPTS"); do
  OUT=$(cast send "$BOOKCACHE" 'poke(uint32)' "$PERP" \
          --account "$ACCOUNT" --password-file "$PASSFILE" \
          --legacy --gas-price "$GAS_PRICE" --rpc-url "$RPC" 2>&1) && { STATUS=0; break; }
  STATUS=$?
  [ "$i" -lt "$ATTEMPTS" ] && sleep 5
done

# Keep stderr. A swallowed rate-limit error reads in a log as a book that would not move.
HASH=$(printf '%s\n' "$OUT" | awk '/^transactionHash/ { print $2 }')
if [ "$STATUS" != "0" ] || [ -z "$HASH" ]; then
  { printf '%s\tFAIL\tperp=%s\tpoker=%s\tattempts=%s\texit=%s\n' "$(date -Is)" "$PERP" "$POKER" "$ATTEMPTS" "$STATUS"
    printf '%s\n' "$OUT" | sed 's/^/\t/'; } >>"$LOG"
  exit "${STATUS:-1}"
fi

GAS=$(printf '%s\n' "$OUT" | awk '/^gasUsed/ { print $2 }')
PX=$(printf '%s\n' "$OUT"  | awk '/^effectiveGasPrice/ { print $2 }')
printf '%s\tOK\tperp=%s\tgas=%s\tprice=%s\t%s\n' "$(date -Is)" "$PERP" "${GAS:-?}" "${PX:-?}" "$HASH" >>"$LOG"
echo "poked perp $PERP · gas ${GAS:-?} · $HASH"
