#!/usr/bin/env bash
# Gives the faucet wallet an owner, which is what makes its policy real.
#
# **The thing this fixes.** A Privy policy attached to a wallet with no owner is not enforced: with
# `owner_id: null`, a request carrying only the app secret is full authority over the wallet. That
# was measured, not assumed — a rule that denied *everything* was attached to this wallet and a send
# still went through to the node. Once the wallet has an owner, every write must also carry a
# `privy-authorization-signature` from that owner's key, and the policy engine evaluates the request.
#
# So after this runs there are two independent secrets and neither is sufficient alone: the app
# secret (Vercel) authenticates the app, and the authorization key signs the request. A leak of the
# Vercel environment does not move the faucet, and the policy caps what the key itself can do.
#
# The private key is generated here, printed once, and never written to disk by this script. Put it
# in `.env` as PRIVY_AUTHORIZATION_KEY and in Vercel as the same name.
#
#   ./script/faucet-owner.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }

: "${PRIVY_APP_ID:?set PRIVY_APP_ID in .env}"
: "${PRIVY_APP_SECRET:?set PRIVY_APP_SECRET in .env}"
: "${PRIVY_FAUCET_WALLET_ID:?set PRIVY_FAUCET_WALLET_ID in .env}"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
openssl ecparam -name prime256v1 -genkey -noout -out "$TMP/key.pem" 2>/dev/null
openssl pkcs8 -topk8 -nocrypt -in "$TMP/key.pem" -out "$TMP/p8.pem" 2>/dev/null
openssl ec -in "$TMP/key.pem" -pubout -out "$TMP/pub.pem" 2>/dev/null
PUB=$(grep -v '^-----' "$TMP/pub.pem" | tr -d '\n')
PRIV=$(grep -v '^-----' "$TMP/p8.pem" | tr -d '\n')

echo "registering a P-256 owner on wallet $PRIVY_FAUCET_WALLET_ID"
OUT=$(curl -s -u "$PRIVY_APP_ID:$PRIVY_APP_SECRET" -H "privy-app-id: $PRIVY_APP_ID" \
  -H "content-type: application/json" -X PATCH \
  "https://api.privy.io/v1/wallets/$PRIVY_FAUCET_WALLET_ID" \
  -d "{\"owner\":{\"public_key\":\"$PUB\"}}")

OWNER=$(printf '%s' "$OUT" | sed -n 's/.*"owner_id":"\([^"]*\)".*/\1/p')
[ -n "$OWNER" ] || { echo "no owner_id came back:"; printf '%s\n' "$OUT"; exit 1; }

echo
echo "owner_id  $OWNER"
echo
echo "Put this in .env and in Vercel's environment (Settings → Environment Variables)."
echo "It is printed once and this script keeps no copy:"
echo
echo "PRIVY_AUTHORIZATION_KEY=wallet-auth:$PRIV"
echo
echo "Then check the policy is live:  node script/faucet-check.mjs"
