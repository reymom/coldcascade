#!/usr/bin/env bash
# Commit the keeper's artifact and put it in front of the page. Once or twice a day, by hand.
#
# `results/markouts.json` is rewritten every twenty minutes by the markout cadence and is the only
# tracked file that churns. Committing it per pass would put seventy commits a day into a git
# history that is itself a graded artifact, so the cadence never touches git and this does — on
# purpose, at a moment somebody chose.
#
# It is also the only thing that refreshes the *deployed* copy: `vercel --prod` uploads the working
# tree, so until this runs the page serves whatever the artifact said at the last deploy.
#
#   ./script/publish-results.sh              # commit and deploy
#   ./script/publish-results.sh --no-deploy  # commit only
set -euo pipefail
cd "$(dirname "$0")/.."

DEPLOY=1; [ "${1:-}" = "--no-deploy" ] && DEPLOY=0

[ -f results/markouts.json ] || { echo "no results/markouts.json — run the keeper first" >&2; exit 1; }

if git diff --quiet -- results/markouts.json; then
  echo "results/markouts.json is unchanged since the last publish."
else
  read -r FILLS COMPLETE BOOKS SPAN < <(python3 -c "
import json; d=json.load(open('results/markouts.json')); s=d['summary']
print(s['fills'], s['fillsWithCompleteHorizons'], d['books']['count'], s['spanDays'])")
  git add results/markouts.json
  git commit -q -m "markouts: $FILLS fills over $SPAN days, $COMPLETE with a complete 5/15/60, $BOOKS books"
  echo "committed: $FILLS fills, $COMPLETE complete, $BOOKS books"
fi

# Anything else staged is somebody else's commit to make; this script only ever publishes the one
# file, so a half-finished change cannot be swept into a deploy by accident.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "note: the working tree has other uncommitted changes; they will still be uploaded by vercel." >&2
fi

if [ "$DEPLOY" = "1" ]; then
  command -v vercel >/dev/null || { echo "vercel not on PATH" >&2; exit 1; }
  vercel --prod --yes 2>&1 | grep -iE "^  Production|Aliased" || true
  echo
  echo "verify on production, never on localhost:"
  curl -sS -m 20 -o /dev/null -w "  /app/ -> %{http_code}\n" https://coldcascade.vercel.app/app/
  curl -sS -m 20 https://coldcascade.vercel.app/results/markouts.json \
    | python3 -c "
import sys, json
d = json.load(sys.stdin); s = d['summary']
print(f\"  live artifact: {s['fills']} fills, {s['fillsWithCompleteHorizons']} complete, {d['books']['count']} books\")"
fi
