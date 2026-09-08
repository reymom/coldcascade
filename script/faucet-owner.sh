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
# **The same key is put on the policy, which is the other half and is easy to miss.** A policy with
# `owner_id: null` *is* enforced — but anything holding the app secret can PATCH its rules, so an
# owned wallet under an unowned policy is a lock with its key hanging beside it. The faucet ran that
# way from 6 to 8 Sep. Both are owned now, and a run against an already-owned policy says so and
# leaves it alone, because changing an owner needs a signature from the current one.
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

# **Re-running this rotates the wallet's owner, and that is almost never what is wanted.** The
# policy below is owned by the key this script printed the last time it ran; a rotated wallet under
# a policy owned by the old key is a state neither secret can repair without that old key. So the
# default is to refuse, and rotating is a deliberate word on the command line.
OWNED=$(curl -s -u "$PRIVY_APP_ID:$PRIVY_APP_SECRET" -H "privy-app-id: $PRIVY_APP_ID" \
  "https://api.privy.io/v1/wallets/$PRIVY_FAUCET_WALLET_ID" | sed -n 's/.*"owner_id":"\([^"]*\)".*/\1/p')
if [ -n "$OWNED" ] && [ "${ROTATE:-0}" != "1" ]; then
  echo "wallet $PRIVY_FAUCET_WALLET_ID is already owned by $OWNED, so its policy is enforced."
  echo "Nothing to do. ROTATE=1 replaces the key — only if the old one is lost, and the policy has"
  echo "to be re-owned in the same run or it stays with the key you just replaced."
  exit 0
fi

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

# The policy, with the key the wallet just took. `owner` is accepted at creation too, which is what
# script/hedge-operator.sh does — this path exists because the faucet's policy predates the rule.
if [ -n "${PRIVY_FAUCET_POLICY_ID:-}" ]; then
  POLICY_URL="https://api.privy.io/v1/policies/$PRIVY_FAUCET_POLICY_ID"
  HAS=$(curl -s -u "$PRIVY_APP_ID:$PRIVY_APP_SECRET" -H "privy-app-id: $PRIVY_APP_ID" "$POLICY_URL" \
        | sed -n 's/.*"owner_id":"\([^"]*\)".*/\1/p')
  if [ -n "$HAS" ]; then
    echo "policy $PRIVY_FAUCET_POLICY_ID is already owned by $HAS — left alone."
    echo "Changing it needs a privy-authorization-signature from that owner, not this script."
  else
    OUT=$(curl -s -u "$PRIVY_APP_ID:$PRIVY_APP_SECRET" -H "privy-app-id: $PRIVY_APP_ID" \
      -H "content-type: application/json" -X PATCH "$POLICY_URL" \
      -d "{\"owner\":{\"public_key\":\"$PUB\"}}")
    POWNER=$(printf '%s' "$OUT" | sed -n 's/.*"owner_id":"\([^"]*\)".*/\1/p')
    [ -n "$POWNER" ] || { echo "the policy did not take an owner:"; printf '%s\n' "$OUT"; exit 1; }
    echo "policy owner_id  $POWNER"
  fi
else
  echo "PRIVY_FAUCET_POLICY_ID is unset, so the policy was left unowned — the app secret alone can"
  echo "rewrite its rules. Set it in .env and run this again."
fi

echo
echo "owner_id  $OWNER"
echo
echo "Put this in .env and in Vercel's environment (Settings → Environment Variables)."
echo "It is printed once and this script keeps no copy:"
echo
echo "PRIVY_AUTHORIZATION_KEY=wallet-auth:$PRIV"
echo
echo "Then check the policy is live:  node script/faucet-check.mjs"
