#!/usr/bin/env bash
# Provisions the automation key that fires `cover()` — and that can do nothing else.
#
# `DeskAccount` has always had the split: `armHedge(armed, maxNotional, operator, maxSlippageBps)`
# lets the owner authorise a ceiling on a device and hand a *scoped* key the trigger inside it. The
# operator can never move funds, because `cover` transfers nothing and every other call on the
# account is `onlyOwner`. Until this script existed the field was set to zero on every desk and the
# owner sent `cover()` by hand, which is the same loop with a person in the middle of it.
#
# The key is a Privy server wallet under a policy that narrows the on-chain permission further —
# from "may call cover on any desk that named me" to one function, one desk, one chain, no value:
#
#   ALLOW  eth_sendTransaction  where  chain_id == 999
#                                 and  to       == the operator desk
#                                 and  value    == 0
#                                 and  the calldata decodes to cover()   (0xe7d931e4)
#   everything else is denied, because a Privy policy denies whatever no rule allows.
#
# **The selector is not a condition on the transaction, because it cannot be.** Privy's
# `ethereum_transaction` source exposes exactly three fields — `to`, `value`, `chain_id` — and the
# API rejects any other by name rather than accepting it and never matching. So which *function* is
# being called is only expressible through `ethereum_calldata`, which decodes the calldata with an
# ABI the condition carries. That is what the last condition below is, and it is the one doing the
# work: the first three would let the operator call anything on this desk.
#
# **Three things have to be true before that policy means anything.** Two are the faucet's, both
# measured rather than read, and both silently turn a policy into decoration:
#
#   1. a policy on a wallet whose `owner_id` is null is not enforced at all;
#   2. a policy is evaluated against the request *as sent*, before Privy populates a transaction, so
#      a partial one leaves every condition unresolvable and passing.
#
# The third belongs to this script. **The policy is given an owner as well as the wallet.** A policy
# with `owner_id: null` can be rewritten by anything holding the app secret alone — so an unowned
# policy guarding an owned wallet is a lock with its key hanging next to it. Both owners here are the
# same P-256 key, generated below, printed once, and never written to disk by this script.
#
# What comes out is checked, not believed:  node script/hedge-check.mjs
#
#   ./script/hedge-operator.sh                    # desk from deployments/999.json → operatorDesk
#   OPERATOR_DESK=0x… ./script/hedge-operator.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }

: "${PRIVY_APP_ID:?set PRIVY_APP_ID in .env}"
: "${PRIVY_APP_SECRET:?set PRIVY_APP_SECRET in .env}"
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

DESK="${OPERATOR_DESK:-$(jq -r '.operatorDesk // empty' deployments/999.json)}"
[ -n "$DESK" ] || { echo "no operator desk: set OPERATOR_DESK or add operatorDesk to deployments/999.json" >&2; exit 1; }
CHAIN="${OPERATOR_CHAIN_ID:-999}"

api() { # method path body
  curl -sS -u "$PRIVY_APP_ID:$PRIVY_APP_SECRET" -H "privy-app-id: $PRIVY_APP_ID" \
    -H "content-type: application/json" -X "$1" "https://api.privy.io/v1$2" ${3:+-d "$3"}
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
openssl ecparam -name prime256v1 -genkey -noout -out "$TMP/key.pem" 2>/dev/null
openssl pkcs8 -topk8 -nocrypt -in "$TMP/key.pem" -out "$TMP/p8.pem" 2>/dev/null
openssl ec -in "$TMP/key.pem" -pubout -out "$TMP/pub.pem" 2>/dev/null
PUB=$(grep -v '^-----' "$TMP/pub.pem" | tr -d '\n')
PRIV=$(grep -v '^-----' "$TMP/p8.pem" | tr -d '\n')

# The ABI is carried by the condition: Privy decodes the calldata with it and compares the function
# name. It is the whole of `cover`'s signature and nothing else, so a policy holding this ABI cannot
# name any other function of the desk.
POLICY=$(jq -n --arg desk "$DESK" --arg chain "$CHAIN" --arg pub "$PUB" '{
  version: "1.0",
  name: "coldcascade hedge operator",
  chain_type: "ethereum",
  owner: { public_key: $pub },
  rules: [{
    # DENY wins over every ALLOW, so this is the one rule that does not depend on the shape of the
    # request being complete. It is written as `value > 0` rather than `value != 0` because there is
    # no `neq`: the operators this field takes are eq, gt, gte, lt, lte, in, contains, starts_with
    # and ends_with. `chain_id` is narrower still — only `eq` and `in` — so "not 999" cannot be
    # written as a rule at all, and the chain guard has to live inside the ALLOW below.
    name: "deny anything that carries value",
    method: "eth_sendTransaction",
    conditions: [{ field_source: "ethereum_transaction", field: "value", operator: "gt", value: "0x0" }],
    action: "DENY"
  }, {
    name: "cover() only, on the operator desk, on 999",
    method: "eth_sendTransaction",
    conditions: [
      { field_source: "ethereum_transaction", field: "chain_id", operator: "eq", value: $chain },
      { field_source: "ethereum_transaction", field: "to",       operator: "eq", value: $desk  },
      { field_source: "ethereum_transaction", field: "value",    operator: "eq", value: "0x0"  },
      { field_source: "ethereum_calldata",    field: "function_name", operator: "eq", value: "cover",
        abi: [{ name: "cover", type: "function", stateMutability: "nonpayable", inputs: [],
                outputs: [ { name: "covered", type: "bool" },
                           { name: "baseAmount", type: "uint256" },
                           { name: "notional", type: "uint256" } ] }] }
    ],
    action: "ALLOW"
  }]
}')

echo "creating the policy: cover() only, on $DESK, chain $CHAIN"
OUT=$(api POST /policies "$POLICY")
PID=$(printf '%s' "$OUT" | jq -r '.id // empty')
[ -n "$PID" ] || { echo "no policy id came back:"; printf '%s\n' "$OUT" | jq . 2>/dev/null || printf '%s\n' "$OUT"; exit 1; }

echo "creating the wallet under it"
OUT=$(api POST /wallets "$(jq -n --arg p "$PID" --arg pub "$PUB" \
        '{chain_type:"ethereum", policy_ids:[$p], owner:{public_key:$pub}}')")
WID=$(printf '%s' "$OUT" | jq -r '.id // empty')
ADDR=$(printf '%s' "$OUT" | jq -r '.address // empty')
if [ -z "$WID" ]; then
  echo "no wallet id came back — the policy $PID exists and is now orphaned:"
  printf '%s\n' "$OUT" | jq . 2>/dev/null || printf '%s\n' "$OUT"; exit 1
fi

# The policy as Privy stores it, beside the faucet's. It is committed so the rule a reader is being
# asked to trust is the rule the wallet is actually held under, ids and all.
api GET "/policies/$PID" | jq . > keeper/hedge-policy.json
echo "wrote keeper/hedge-policy.json"

cat <<TXT

policy    $PID   (owner set: $(jq -r '.owner_id // "NONE — the app secret alone could rewrite it"' keeper/hedge-policy.json))
wallet    $WID
operator  $ADDR

Put these in .env. The key is printed once and this script keeps no copy:

PRIVY_HEDGE_WALLET_ID=$WID
PRIVY_HEDGE_POLICY_ID=$PID
PRIVY_HEDGE_OPERATOR=$ADDR
PRIVY_HEDGE_AUTHORIZATION_KEY=wallet-auth:$PRIV

Then, in this order — the check first, because it costs nothing and a wallet that fails it should
not be given either gas or a desk:

  1. prove the policy refuses everything else
     node script/hedge-check.mjs
  2. name it on the desk. This is the owner's signature, and it is the half no policy can do:
     the ceiling and the operator are state on the account.
     cast send $DESK 'armHedge(bool,uint64,address,uint16)' true <ceiling> $ADDR <bps> \\
       --account coldcascade-deployer --legacy --rpc-url \$HYPEREVM_RPC_URL
  3. give it gas. It can hold HYPE and can never send any anywhere: the policy denies any
     transaction carrying value, so what it holds leaves only as the gas for a cover.
     cast send $ADDR --value 0.01ether --account coldcascade-deployer --legacy --rpc-url \$HYPEREVM_RPC_URL
  4. fire one, and read the effect on HyperCore rather than the receipt
     FORCE=1 node script/cover.mjs
TXT
