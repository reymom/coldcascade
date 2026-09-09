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
# It refreshes results/markouts.json **on disk**. The copy the deployed page serves is whatever
# was in the working tree at the last `vercel --prod`, so the live artifact is as old as the last
# deploy, not as old as the last pass. Deliberate: a cron that deploys would push whatever happens
# to be uncommitted at the time.
#
#   ./script/markout-cadence.sh
#   DRY_RUN=1 ./script/markout-cadence.sh     # never send, whatever keys are present
set -euo pipefail
cd "$(dirname "$0")/.."

command -v cast >/dev/null || PATH="$HOME/.foundry/bin:$PATH"
command -v substreams >/dev/null || PATH="$HOME/.local/bin:$PATH"
command -v cast >/dev/null || { echo "cast not found (looked in ~/.foundry/bin)" >&2; exit 1; }
command -v substreams >/dev/null || { echo "substreams not found (looked in ~/.local/bin)" >&2; exit 1; }

# .env fills in what the environment has not already set, rather than overwriting it. The other
# way round means the overrides this script documents silently do nothing whenever the variable
# also appears in .env — which is how a test of the endpoint fallback passed this morning while
# still talking to the real endpoint.
if [ -f .env ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; *=*) ;; *) continue ;; esac
    key=${line%%=*}
    [ -n "${!key+set}" ] || export "$key=${line#*=}"
  done < .env
fi
: "${PINAX_JWT:?no PINAX_JWT in .env — the stream will not authenticate}"

LOG="${MARKOUT_LOG:-$HOME/.config/coldcascade/markout.log}"
ACCOUNT="${MARKOUT_ACCOUNT:-${DEPLOYER_ACCOUNT:-coldcascade-deployer}}"
PASSFILE="${MARKOUT_PASSFILE:-$HOME/.config/coldcascade/deployer.pass}"
DRY_RUN="${DRY_RUN:-0}"

# Bounded per pass, and the bound is about the *lock*, not the gas. Every send here is a send the
# poke cannot make: the poke skips a minute rather than queue behind this, so a long pass is a
# long gap in the very book series these markouts are computed from. Twelve sends is roughly
# forty seconds of held lock, three times an hour. Generation is about nine markouts an hour
# (three fills, three horizons), so a limit of twelve still drains a backlog while it does it.
LIMIT="${MARKOUT_LIMIT:-12}"

ARGS=()
if [ "$DRY_RUN" != "1" ] && [ -f "$PASSFILE" ]; then
  ARGS=(--post --account "$ACCOUNT" --password-file "$PASSFILE" --limit "$LIMIT")
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
# Counted out of the artifact, not off the console. The keeper prints a "post …" line for every
# markout it *would* send, dry run included, so grepping those reported posted=1 on a run that
# sent nothing — a log that says a thing was written to the chain when it was not is the same
# failure as a swallowed error, pointing the other way.
POSTED=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["postedThisRun"]))' \
           results/markouts.json 2>/dev/null || echo '?')
printf '%s\tOK\tposted=%s\t%s\n' "$(date -Is)" "$POSTED" "${SUMMARY:-?}" >>"$LOG"
