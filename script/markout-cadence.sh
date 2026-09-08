#!/usr/bin/env bash
# Read Graph, decide, write chain — on a schedule.
#
# One pass of `python -m coldcascade markouts`: stream the desk's fills and books off Substreams,
# join each fill to the books at t+5, t+15 and t+60 minutes, post what is new to MarkoutLedger,
# and rewrite results/markouts.json for the page. The Markout logs it writes are decoded by the
# same Substreams module on the next pass, which is how the keeper knows what it has already
# said and cannot restate it.
#
# Posting needs the poster's key. Without it this still runs and still refreshes the artifact —
# it just does not send. That is deliberate: the page should never go stale because a keystore
# password is missing.
#
#   ./script/markout-cadence.sh
#   DRY_RUN=1 ./script/markout-cadence.sh     # never send, whatever keys are present
set -euo pipefail
cd "$(dirname "$0")/.."

command -v cast >/dev/null || PATH="$HOME/.foundry/bin:$PATH"
command -v substreams >/dev/null || PATH="$HOME/.local/bin:$PATH"
command -v cast >/dev/null || { echo "cast not found (looked in ~/.foundry/bin)" >&2; exit 1; }
command -v substreams >/dev/null || { echo "substreams not found (looked in ~/.local/bin)" >&2; exit 1; }

[ -f .env ] && { set -a; . ./.env; set +a; }
: "${PINAX_JWT:?no PINAX_JWT in .env — the stream will not authenticate}"

LOG="${MARKOUT_LOG:-$HOME/.config/coldcascade/markout.log}"
ACCOUNT="${MARKOUT_ACCOUNT:-${DEPLOYER_ACCOUNT:-coldcascade-deployer}}"
PASSFILE="${MARKOUT_PASSFILE:-$HOME/.config/coldcascade/deployer.pass}"
DRY_RUN="${DRY_RUN:-0}"

ARGS=()
if [ "$DRY_RUN" != "1" ] && [ -f "$PASSFILE" ]; then
  ARGS=(--post --account "$ACCOUNT" --password-file "$PASSFILE")
else
  echo "no $PASSFILE (or DRY_RUN=1) — refreshing results/markouts.json without posting" >&2
fi

# The poster is also the poke key once its password is on disk, and HyperEVM rejects a nonce
# ahead of the account rather than queueing it. Held for the whole pass: a poke that waits
# thirty seconds is a 90-second gap in a series whose horizons tolerate 180.
exec 9>"$HOME/.config/coldcascade/send.lock"
flock -w 300 9 || { echo "could not take the send lock in 300s" >&2; exit 3; }

STATUS=0
OUT=$(cd keeper && python3 -m coldcascade markouts "${ARGS[@]}" 2>&1) || STATUS=$?
printf '%s\n' "$OUT"

if [ "$STATUS" != "0" ]; then
  { printf '%s\tFAIL\texit=%s\n' "$(date -Is)" "$STATUS"; printf '%s\n' "$OUT" | sed 's/^/\t/'; } >>"$LOG"
  exit "$STATUS"
fi

SUMMARY=$(printf '%s\n' "$OUT" | grep -E '^[0-9]+ fills over' || true)
POSTED=$(printf '%s\n' "$OUT" | grep -c '^  post ' || true)
printf '%s\tOK\tposted=%s\t%s\n' "$(date -Is)" "$POSTED" "${SUMMARY:-?}" >>"$LOG"
