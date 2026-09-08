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

# Two endpoints, and the reason is the page rather than the poke. One poke a minute is about
# 8 600 RPC calls a day, which is the largest single consumer we have, and it shares the public
# node with every browser that opens the console — the node answered `-32005 rate limited` to two
# consecutive calls on 8 Sep. A throttled keeper retries; a throttled console sits at
# "connecting to HyperEVM…" in front of a judge on Monday. So the cadences move off it.
#
# The fallback is not decoration: a third party that goes down must not be able to stop the book
# series, so the attempts below alternate between the two.
RPC="${POKE_RPC_URL:-https://rpc.hypurrscan.io}"
RPC_FALLBACK="${HYPEREVM_RPC_URL:-https://rpc.hyperliquid.xyz/evm}"
PERP="${PERP:-0}"
LOG="${POKE_LOG:-$HOME/.config/coldcascade/poke.log}"
DRY_RUN="${DRY_RUN:-0}"
# **Do not pin this.** 999's base fee sits at its 0.1 gwei floor almost all the time, which is
# what made a flat 0.15 gwei look safe — and then at 15:27 on 8 Sep it went to 2.17 gwei for a few
# minutes. A legacy transaction priced under the base fee is not rejected: it is *accepted into
# the mempool and never mined*, so the nonce jams, every following minute resubmits a byte-identical
# transaction, the node answers "already known", and the book series stops. It stopped for
# nineteen minutes before anyone noticed, and nothing in the log said "gas".
#
# So: pay a quarter over the live base fee, never less than the floor, and above the cap decline
# to poke at all. A gap in the series is recoverable; 1 440 pokes a day at 2 gwei is 0.15 HYPE a
# day against a poster holding 0.147, and that is not.
MIN_GAS_WEI="${POKE_MIN_GAS_WEI:-150000000}"      # 0.15 gwei
# 8 gwei. Not a budget limit — the proportional interval already fixes the budget — but the point
# past which the granularity is worthless: at 8 gwei the interval is 32 minutes, and a series that
# coarse cannot bound a five-minute horizon at all.
MAX_GAS_WEI="${POKE_MAX_GAS_WEI:-8000000000}"
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
# 0.02 HYPE held back. Not "enough for one more poke" — enough that the markout keeper, which
# signs from the same account, still has gas to post with after the book series has spent itself.
# The first version of this line was 8e12 wei and its comment claimed a thousand pokes; 8e12 wei
# is one poke.
FLOOR=20000000000000000
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
#
# **Twenty seconds, and then give up on this minute.** The first version waited 300, and on 8 Sep
# at 15:34 that turned one held lock into a pile-up: five cron minutes queued behind the markout
# keeper's sends, all took the lock within ninety seconds of each other, all computed the same
# nonce, and four came back "already known" while the book went 319 seconds without a poke. A
# skipped minute is a 120-second gap, inside the 180-second horizon tolerance. A queue is not.
exec 9>"$HOME/.config/coldcascade/send.lock"
if ! flock -w "${POKE_LOCK_WAIT:-20}" 9; then
  printf '%s\tSKIP\tperp=%s\tanother sender holds the lock\n' "$(date -Is)" "$PERP" >>"$LOG"
  echo "another sender holds the send lock; skipping this minute" >&2
  exit 0
fi

# `--legacy` is not cosmetic. Without it cast builds a 1559 transaction, sets maxFeePerGas from
# --gas-price, and takes maxPriorityFeePerGas from the node's own suggestion — which on 999 is
# sometimes above 0.15 gwei, and the node then rejects its own advice with
# "max priority fee per gas higher than max fee per gas". A legacy transaction has one number.
#
# And it retries: at one send a minute against a public RPC, a transient -32602 is a normal
# Tuesday. A book series with a hole in it is worth five seconds of sleep.
# What the network is charging right now, and whether it is worth paying.
BASEFEE=$(cast base-fee --rpc-url "$RPC" 2>/dev/null || echo "")
case "$BASEFEE" in ''|*[!0-9]*) BASEFEE="$MIN_GAS_WEI" ;; esac
WANT=$(( BASEFEE * 5 / 4 ))
[ "$WANT" -lt "$MIN_GAS_WEI" ] && WANT="$MIN_GAS_WEI"
# Cron fires every minute; how many of those minutes are worth spending depends on the price.
# Thinning the cadence instead of stopping it keeps the series alive through a spike and keeps the
# daily cost flat at roughly 0.02 HYPE across every tier — one poke a minute at 0.25 gwei and one
# every five at 1 gwei cost the same per day. Above the cap nothing is worth it.
# One rule instead of three tiers: **hold the spend per day constant and let the interval stretch
# with the price.** EVERY = price / 0.25 gwei, so a poke costs the same per day at any gas price —
# about 0.018 HYPE — and the series degrades in granularity rather than stopping. The tiers this
# replaces fell off a cliff: above 1 gwei they poked not at all, and tonight's spike put sixteen
# consecutive minutes into that bucket, which is a hole in the series every markout is measured
# against. A book every twelve minutes still bounds a sixty-minute horizon. Nothing does not.
EVERY=$(( WANT / 250000000 )); [ "$EVERY" -lt 1 ] && EVERY=1
if [ "$WANT" -le "$MAX_GAS_WEI" ]; then :
else
  printf '%s\tSKIP\tperp=%s\tgas too dear: base %s, would pay %s, cap %s\n' \
    "$(date -Is)" "$PERP" "$BASEFEE" "$WANT" "$MAX_GAS_WEI" >>"$LOG"
  echo "base fee $BASEFEE wei; skipping rather than paying $WANT" >&2
  exit 0
fi
# Thinned by *time since the last poke*, not by minute-of-hour. A modulo rule looks equivalent
# and is not: the tier is chosen from the instantaneous base fee, so on a flapping fee it changes
# between runs and the minute never lines up — 15:55 to 15:58 on 8 Sep skipped four in a row,
# alternating between 1-in-2 and 1-in-5 and matching neither. This says what is actually meant,
# which is at most one poke per EVERY minutes and at least one.
if [ "$EVERY" -gt 1 ]; then
  LAST=$(awk -F'\t' '$2=="OK" {t=$1} END {print t}' "$LOG" 2>/dev/null)
  if [ -n "$LAST" ]; then
    AGE=$(( $(date +%s) - $(date -d "$LAST" +%s 2>/dev/null || echo 0) ))
    if [ "$AGE" -lt $(( EVERY * 60 - 10 )) ]; then
      printf '%s\tSKIP\tperp=%s\tthinned to 1-in-%s at %s wei; last poke %ss ago\n' \
        "$(date -Is)" "$PERP" "$EVERY" "$WANT" "$AGE" >>"$LOG"
      echo "gas at $WANT wei; last poke ${AGE}s ago, want one every ${EVERY}m" >&2
      exit 0
    fi
  fi
fi
GAS_PRICE="${WANT}"

# The lock stops two of our scripts *signing* at once. It does not stop one of them having left a
# transaction in the mempool: a `cast send` that errors after the node accepted it releases the
# lock with the nonce still in flight, and the next signer computes the same nonce and is told
# `replacement transaction underpriced`. The node's own pending-vs-latest count is the answer to
# "is there anything of mine still out there", and this minute is cheap to skip.
PEND=$(cast rpc eth_getTransactionCount "$POKER" pending --rpc-url "$RPC" 2>/dev/null | tr -d '"')
LAST=$(cast rpc eth_getTransactionCount "$POKER" latest  --rpc-url "$RPC" 2>/dev/null | tr -d '"')
if [ -n "$PEND" ] && [ -n "$LAST" ] && [ "$PEND" != "$LAST" ]; then
  printf '%s\tSKIP\tperp=%s\t%s has a transaction pending (%s vs %s)\n' \
    "$(date -Is)" "$PERP" "$POKER" "$PEND" "$LAST" >>"$LOG"
  echo "poker has a transaction pending; skipping this minute" >&2
  exit 0
fi

# What was already true before this ran, so "did the poke land" is answerable afterwards.
WAS=$(cast call "$BOOKCACHE" 'pokedAt(uint32)(uint64)' "$PERP" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
WAS="${WAS:-0}"

STATUS=1; OUT=""; TRIED=0
for i in $(seq 1 "$ATTEMPTS"); do
  TRIED=$i
  # Even attempts go to the other endpoint. If one of them is throttling or down, the minute is
  # still poked rather than logged as a failure of the chain.
  if [ $(( i % 2 )) -eq 0 ]; then USE="$RPC_FALLBACK"; else USE="$RPC"; fi
  OUT=$(cast send "$BOOKCACHE" 'poke(uint32)' "$PERP" \
          --account "$ACCOUNT" --password-file "$PASSFILE" \
          --legacy --gas-price "$GAS_PRICE" --rpc-url "$USE" 2>&1) && { STATUS=0; break; }
  STATUS=$?

  # Not every failure means nothing was sent, and resending the ones that did is how you get four
  # "already known" in a row for one poke that worked. These say the transaction is already in
  # flight; the chain is then the thing to ask, not the RPC again.
  case "$OUT" in
    *"already known"*|*"nonce too low"*|*"replacement transaction underpriced"*)
      NOW=$(cast call "$BOOKCACHE" 'pokedAt(uint32)(uint64)' "$PERP" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
      if [ -n "${NOW:-}" ] && [ "$NOW" -gt "$WAS" ]; then
        printf '%s\tOK\tperp=%s\tin flight from another attempt; pokedAt %s -> %s\n' \
          "$(date -Is)" "$PERP" "$WAS" "$NOW" >>"$LOG"
        echo "poke already in flight and the book moved on ($WAS -> $NOW)"
        exit 0
      fi
      break ;;
  esac

  # The public RPC does rate-limit us, and five seconds is not a pause it notices.
  case "$OUT" in
    *"rate limited"*|*-32005*) [ "$i" -lt "$ATTEMPTS" ] && sleep 20 ;;
    *)                         [ "$i" -lt "$ATTEMPTS" ] && sleep 5 ;;
  esac
done

# Keep stderr. A swallowed rate-limit error reads in a log as a book that would not move.
HASH=$(printf '%s\n' "$OUT" | awk '/^transactionHash/ { print $2 }')
if [ "$STATUS" != "0" ] || [ -z "$HASH" ]; then
  { printf '%s\tFAIL\tperp=%s\tpoker=%s\ttried=%s\texit=%s\n' "$(date -Is)" "$PERP" "$POKER" "$TRIED" "$STATUS"
    printf '%s\n' "$OUT" | sed 's/^/\t/'; } >>"$LOG"
  exit "${STATUS:-1}"
fi

GAS=$(printf '%s\n' "$OUT" | awk '/^gasUsed/ { print $2 }')
PX=$(printf '%s\n' "$OUT"  | awk '/^effectiveGasPrice/ { print $2 }')
printf '%s\tOK\tperp=%s\tgas=%s\tprice=%s\t%s\n' "$(date -Is)" "$PERP" "${GAS:-?}" "${PX:-?}" "$HASH" >>"$LOG"
echo "poked perp $PERP · gas ${GAS:-?} · $HASH"
