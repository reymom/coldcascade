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

if git diff --quiet -- results/markouts.json results/book-archive.json; then
  echo "results/ is unchanged since the last publish."
else
  read -r FILLS COMPLETE BOOKS SPAN < <(python3 -c "
import json; d=json.load(open('results/markouts.json')); s=d['summary']
print(s['fills'], s['fillsWithCompleteHorizons'], d['books']['count'], s['spanDays'])")
  # `--only` and an explicit pathspec, not `git add` then `git commit`. A bare commit takes
  # everything already in the index, and on 8 Sep this script swept a staged file deletion into a
  # commit whose message said "markouts: 21 fills". A script that promises to publish one file
  # must be unable to publish anything else.
  # `-m` before the `--`: everything after the separator is a pathspec, so a message placed
  # there is looked up as a filename and the commit dies with "did not match any file(s)".
  git commit -q -m "markouts: $FILLS fills over $SPAN days, $COMPLETE with a complete 5/15/60, $BOOKS books" \
    --only -- results/markouts.json results/book-archive.json
  echo "committed: $FILLS fills, $COMPLETE complete, $BOOKS books"
fi

# Anything else staged is somebody else's commit to make. The commit above cannot take it, but
# `vercel --prod` uploads the working tree rather than the git tree, so it still ships.
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
