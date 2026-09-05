#!/usr/bin/env bash
# Runs the compiled CoreQuote against the live HyperCore book on chain 999, with nothing deployed.
#
# Three eth_calls and no key:
#   1. a state override plants CorePrecompiles' runtime at a throwaway address;
#   2. an eth_call with no `to` runs CoreQuote's *constructor* against that override and returns its
#      runtime with the READER immutable already baked in — which is how a contract with a
#      constructor argument gets planted without a deployment;
#   3. both are planted and the real bounds()/regime() answer against the real book.
#
# This is what the Floor draws before Monday's deploy, and the reproduction of it afterwards.
#
#   forge build && ./script/probe999.sh [rpc-url]
set -euo pipefail

RPC="${1:-${HYPEREVM_RPC_URL:-https://rpc.hyperliquid.xyz/evm}}"
PERP="${PERP:-0}"
READER=0x00000000000000000000000000000000C01dCa5c
QUOTE=0x00000000000000000000000000000000C01dCa5d

# The canonical desk's parameters. Tokens are irrelevant to bounds() and regime(), which read the
# book and the maker's spreads and nothing else, so they are left zero and the answer is the same.
QUIET_BPS="${QUIET_BPS:-20}"
LEAN_BPS="${LEAN_BPS:-15}"
STRESS_BPS="${STRESS_BPS:-25}"
MAP_ORACLE="${MAP_ORACLE:-0x0000000000000000000000000000000000000000}"
MAP_MAX_AGE="${MAP_MAX_AGE:-300}"
MAP_MIN_NOTIONAL="${MAP_MIN_NOTIONAL:-5000000}"

PRE=$(jq -r '.deployedBytecode.object' out/CorePrecompiles.sol/CorePrecompiles.json)
CREATE=$(jq -r '.bytecode.object' out/CoreQuote.sol/CoreQuote.json)

rpc() { # method, params
  curl -sS -X POST "$RPC" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"
}
call() { # to, data, block, overrides -> 0x… or ERROR
  rpc eth_call "[{\"to\":\"$1\",\"data\":\"$2\",\"gas\":\"0x2faf080\"},\"$3\",$4]" \
    | jq -r '.result // ("ERROR: " + .error.message)'
}
word() { printf '%d\n' "0x${1:2+64*$2:64}"; }
usd()  { python3 -c "print(f'{$1/10:,.1f}')"; }   # raw / 10^(6-szDecimals), BTC szDecimals 5

CHAIN=$(printf '%d' "$(rpc eth_chainId '[]' | jq -r .result)")
BLOCK=$(printf '%d' "$(rpc eth_blockNumber '[]' | jq -r .result)")
echo "chain $CHAIN, block $BLOCK, perp $PERP, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

# 2. run the constructor under the reader override; the return value is the runtime code.
ARG=$(printf '%064x' "$(printf '%d' "$READER")")
RUNTIME=$(rpc eth_call \
  "[{\"data\":\"${CREATE}${ARG}\",\"gas\":\"0x2faf080\"},\"latest\",{\"$READER\":{\"code\":\"$PRE\"}}]" \
  | jq -r '.result // ("ERROR: " + .error.message)')
case "$RUNTIME" in 0x*) ;; *) echo "constructor: $RUNTIME"; exit 1 ;; esac
echo "CoreQuote runtime from its own constructor: $(( (${#RUNTIME} - 2) / 2 )) bytes, READER = $READER"

OV="{\"$READER\":{\"code\":\"$PRE\"},\"$QUOTE\":{\"code\":\"$RUNTIME\"}}"
PARAMS="(0x0000000000000000000000000000000000000000,0x0000000000000000000000000000000000000000,$PERP,1,1000,$QUIET_BPS,$LEAN_BPS,$STRESS_BPS,$MAP_ORACLE,$MAP_MAX_AGE,$MAP_MIN_NOTIONAL,0,340282366920938463463374607431768211455)"
STRUCT='(address,address,uint32,uint64,uint64,uint16,uint16,uint16,address,uint32,uint128,uint128,uint128)'

B=$(call "$READER" "$(cast calldata 'read(uint32)' "$PERP")" latest "$OV")
Q=$(call "$QUOTE"  "$(cast calldata "bounds($STRUCT)" "$PARAMS")" latest "$OV")
G=$(call "$QUOTE"  "$(cast calldata "regime($STRUCT)" "$PARAMS")" latest "$OV")
case "$B$Q$G" in *ERROR*) echo "$B"; echo "$Q"; echo "$G"; exit 1 ;; esac

echo
printf 'L1     bid %-9s ask %-9s mark %-9s oracle %s\n' "$(word "$B" 0)" "$(word "$B" 1)" "$(word "$B" 2)" "$(word "$B" 3)"
printf '       $%-10s $%-10s $%-10s $%s\n' \
  "$(usd "$(word "$B" 0)")" "$(usd "$(word "$B" 1)")" "$(usd "$(word "$B" 2)")" "$(usd "$(word "$B" 3)")"
printf 'desk   bid %-9s ask %-9s  ($%s / $%s)\n' \
  "$(word "$Q" 0)" "$(word "$Q" 1)" "$(usd "$(word "$Q" 0)")" "$(usd "$(word "$Q" 1)")"
LEAN=$(word "$Q" 2)
printf 'lean   %s   quiet %s bps, lean %s bps, stress %s bps\n' \
  "$(case $LEAN in 0) echo none;; 1) echo bid;; 2) echo ask;; esac)" "$QUIET_BPS" "$LEAN_BPS" "$STRESS_BPS"
DISL=$(python3 -c "v=$(word "$G" 1); print(v - (1<<256) if v >= (1<<255) else v)")
printf 'regime dislocation %s bps   map below %s above %s fresh %s\n' \
  "$DISL" "$(word "$G" 2)" "$(word "$G" 3)" "$(word "$G" 4)"

echo
echo "does the book honour a historical block tag?"
# the precompile takes a bare abi-encoded index, no selector
D=$(cast abi-encode 'f(uint32)' "$PERP")
for back in 0 2000 200000; do
  TAG=$(printf '0x%x' $((BLOCK - back)))
  R=$(call 0x000000000000000000000000000000000000080e "$D" "$TAG" '{}')
  case "$R" in
    0x*) printf '  %-9s ago  bid %-9s ask %s\n' "$back blk" "$(word "$R" 0)" "$(word "$R" 1)" ;;
    *)   printf '  %-9s ago  %s\n' "$back blk" "$R" ;;
  esac
done
echo "  Identical rows mean the precompiles are node state, not chain state: there is no archive"
echo "  read of the book, which is the whole reason BookCache writes the series into logs."
