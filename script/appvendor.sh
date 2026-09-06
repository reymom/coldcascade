#!/usr/bin/env bash
# Bundles Privy's SDK into the one vendored file the console loads, and writes the console's public
# Privy config out of `.env`.
#
# **Why this toolchain lives in `script/vendor/` and not in the root `package.json`.** The root
# package pins `@1inch/aqua` and `@1inch/swap-vm` to GitHub tags and holds `@1inch/solidity-utils`
# at 6.9.10 through `resolutions`. A single `yarn add` at the root re-resolves that graph: it
# rewrote swap-vm's own dependency edges, installed a different swap-vm tree from cache, and
# `forge build` stopped finding `ProgramBuilder.sol` — a broken contract build caused by adding a
# JavaScript bundler. The console's toolchain has nothing to do with the Solidity graph, so it gets
# its own package and its own lockfile and cannot reach the one that matters.
#
# The page has no build step and no runtime CDN: `app/src/abi.js` is a hand-written codec precisely
# so no third party sits between a judge's browser and the calldata that goes to 1inch's router. A
# wallet is the one place that argument does not apply — an embedded wallet IS a third party holding
# a key, chosen deliberately — so Privy is vendored here, pinned by `script/vendor/yarn.lock`, and
# committed so the site stays a set of static files. `app/src/signer.js` imports it lazily, so the
# read path still runs on this repository's own code alone.
#
#   ./script/appvendor.sh     # after any bump in script/vendor/package.json, or a new PRIVY_APP_ID
set -euo pipefail
cd "$(dirname "$0")/.."

VENDOR=script/vendor
[ -d "$VENDOR/node_modules" ] || (cd "$VENDOR" && yarn install --frozen-lockfile --ignore-scripts)

ESBUILD="$VENDOR/node_modules/@esbuild/linux-x64/bin/esbuild"
[ -x "$ESBUILD" ] || ESBUILD="$VENDOR/node_modules/.bin/esbuild"
[ -x "$ESBUILD" ] || { echo "esbuild is missing: (cd $VENDOR && yarn install --ignore-scripts)" >&2; exit 1; }

SDK="$VENDOR/node_modules/@privy-io/js-sdk-core/package.json"
VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SDK" | head -1)
OUT=app/vendor/privy.js
mkdir -p app/vendor

ENTRY=$(mktemp -p "$VENDOR" --suffix=.mjs)
trap 'rm -f "$ENTRY"' EXIT

# Four names, which is the whole surface the console uses. Naming them rather than re-exporting the
# package keeps the bundle to what is actually called, and makes an SDK release that drops one of
# them a failure here rather than a stack trace in front of a judge.
cat > "$ENTRY" <<'JS'
export {
  default as Privy,
  LocalStorage,
  getUserEmbeddedEthereumWallet,
  getEntropyDetailsFromUser,
} from "@privy-io/js-sdk-core";
JS

"$ESBUILD" "$ENTRY" \
  --bundle --format=esm --platform=browser --target=es2022 --minify \
  --legal-comments=none --log-level=error --outfile="$OUT"

# Provenance: a committed 860 kB blob with no note is indistinguishable from one somebody pasted in.
printf '// @privy-io/js-sdk-core %s, bundled by script/appvendor.sh. Do not edit.\n' "$VERSION" \
  | cat - "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

# ---- the public half of the Privy config ----
#
# A Privy app id is public: it ships inside every client bundle that uses it, and Privy gates the
# app on an allowlist of origins rather than on the id being secret. So it is committed, and it is
# written out of `.env` rather than typed here — the same rule as every selector in the console.
# The APP SECRET is a different object and appears nowhere in this repository or this bundle: it is
# a Vercel environment variable read by `api/faucet.js` on the server.
[ -f .env ] && { set -a; . ./.env; set +a; }
APP_ID="${PRIVY_APP_ID:-}"
CLIENT_ID="${PRIVY_CLIENT_ID:-}"
[ -n "$APP_ID" ] || echo "PRIVY_APP_ID is unset — writing an empty app id; the console will say Privy is not configured" >&2

python3 - "$APP_ID" "$CLIENT_ID" <<'PY'
import json, sys
app_id, client_id = sys.argv[1], sys.argv[2]
json.dump({"appId": app_id, "clientId": client_id or None}, open("app/privy.json", "w"), indent=2)
open("app/privy.json", "a").write("\n")
PY

printf '%s  %s  (%s gzipped)\n' "$OUT" \
  "$(du -h "$OUT" | cut -f1)" "$(gzip -c "$OUT" | wc -c | numfmt --to=iec)"
printf 'app/privy.json  appId %s\n' "${APP_ID:-<empty>}"
