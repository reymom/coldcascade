#!/usr/bin/env bash
# Monday's deploy on chain 999, with every check that can be made from a read in front of it.
#
#   ./script/mainnet.sh          # preflight only, then print the three commands
#   ./script/mainnet.sh --go     # preflight, then broadcast all three
#
# The preflight is the point. A deploy here costs real HYPE and the three scripts hand state to
# each other through deployments/999.json, so a wrong token address or an unfunded deployer is a
# half-finished mainnet that has to be redeployed at new addresses. Everything below is an eth_call.
#
# Needs: HYPEREVM_RPC_URL, a keystore account (cast wallet new ~/.foundry/keystores) and its address
# in DEPLOYER. Nothing here reads a private key and nothing here signs.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

RPC="${HYPEREVM_RPC_URL:-https://rpc.hyperliquid.xyz/evm}"
ACCOUNT="${DEPLOYER_ACCOUNT:-coldcascade-deployer}"
GO=false
[ "${1:-}" = "--go" ] && GO=true

AQUA="${AQUA:-0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a}"
ROUTER="${SWAPVM_ROUTER:-0x111111338c5091E8440b67B168bAe16a668AC0De}"
# Mirrors script/base/Addresses.sol. Read back below rather than trusted.
UBTC="${BASE_TOKEN:-0x9FDBdA0A5e284c32744D2f17Ee5c74B284993463}"
USDT0="${QUOTE_TOKEN:-0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb}"
BBO=0x000000000000000000000000000000000000080e

# What Ship.s.sol will move. Same defaults, same env vars: change them in one place, .env.
CANONICAL_BASE="${CANONICAL_BASE:-12500}"        # 0.000125 UBTC, ~$10
CANONICAL_QUOTE="${CANONICAL_QUOTE:-10000000}"   # 10 USDT0
# Deploy + ship + one swap, measured on the 999 fork in results/999_deploy_budget.md, at 0.1 gwei
# and with room for the estimate padding. Under-funding here is the failure that wastes a morning.
MIN_HYPE_WEI=200000000000000000                  # 0.2 HYPE

fail=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; }
num()  { awk '{print $1}'; }                     # cast appends "[1.2e3]" to uint256 output

echo "coldcascade — mainnet preflight"
echo "  rpc      $RPC"
echo "  account  $ACCOUNT (keystore name; no key is read here)"
echo

# ---- the chain ----
CHAIN=$(cast chain-id --rpc-url "$RPC")
BLOCK=$(cast block-number --rpc-url "$RPC")
[ "$CHAIN" = "999" ] && ok "chain $CHAIN, block $BLOCK" || bad "chain is $CHAIN, expected 999"

# ---- the deployer ----
if [ -z "${DEPLOYER:-}" ]; then
  warn "DEPLOYER is unset; asking the keystore for it, which will prompt for the password"
  DEPLOYER=$(cast wallet address --account "$ACCOUNT")
fi
BAL=$(cast balance "$DEPLOYER" --rpc-url "$RPC")
HYPE=$(cast from-wei "$BAL")
if [ "$(printf '%s\n%s\n' "$BAL" "$MIN_HYPE_WEI" | sort -g | head -1)" = "$MIN_HYPE_WEI" ]; then
  ok "deployer $DEPLOYER holds $HYPE HYPE"
else
  bad "deployer $DEPLOYER holds $HYPE HYPE, wants at least $(cast from-wei $MIN_HYPE_WEI)"
fi

# ---- 1inch's own contracts, which we do not deploy ----
for pair in "Aqua:$AQUA" "SwapVM router:$ROUTER"; do
  name=${pair%%:*}; addr=${pair##*:}
  size=$(( ($(cast code "$addr" --rpc-url "$RPC" | wc -c) - 3) / 2 ))
  [ "$size" -gt 0 ] && ok "$name $addr, $size bytes" || bad "$name $addr has no code"
done

# ---- the real pair: the address, and that it is the token the address is supposed to be ----
check_token() { # label, address, expected symbol, expected decimals, amount Ship will move
  local label=$1 addr=$2 want_sym=$3 want_dec=$4 need=$5
  local sym dec bal
  sym=$(cast call "$addr" 'symbol()(string)' --rpc-url "$RPC" 2>/dev/null | tr -d '"') || { bad "$label $addr does not answer symbol()"; return; }
  dec=$(cast call "$addr" 'decimals()(uint8)' --rpc-url "$RPC" | num)
  bal=$(cast call "$addr" 'balanceOf(address)(uint256)' "$DEPLOYER" --rpc-url "$RPC" | num)
  [ "$sym" = "$want_sym" ] || warn "$label symbol reads \"$sym\", expected \"$want_sym\" — check the address"
  [ "$dec" = "$want_dec" ] && ok "$label $addr, $sym, $dec decimals" || bad "$label decimals are $dec, expected $want_dec"
  if [ "$(printf '%s\n%s\n' "$bal" "$need" | sort -g | head -1)" = "$need" ]; then
    ok "$label balance $(cast from-wei "$bal" 2>/dev/null || echo "$bal") raw $bal, ships $need"
  else
    bad "$label balance is $bal, Ship.s.sol moves $need — fund the deployer first"
  fi
}
check_token "UBTC " "$UBTC"  "UBTC"  8 "$CANONICAL_BASE"
check_token "USDT0" "$USDT0" "USD₮0" 6 "$CANONICAL_QUOTE"

# ---- the book the desk quotes from ----
BOOK=$(cast call "$BBO" "$(cast abi-encode 'f(uint32)' "${PERP_INDEX:-0}")" --rpc-url "$RPC" 2>/dev/null || echo "")
if [ -n "$BOOK" ] && [ "$BOOK" != "0x" ]; then
  BID=$(printf '%d' "0x${BOOK:2:64}"); ASK=$(printf '%d' "0x${BOOK:66:64}")
  [ "$BID" -gt 0 ] && ok "BBO perp ${PERP_INDEX:-0}: bid $BID ask $ASK" || bad "BBO answered zero"
else
  bad "0x080e did not answer — the node is not serving the precompiles"
fi

# ---- a deployment already here is a rerun, and reruns overwrite the console's addresses ----
[ -f deployments/999.json ] && warn "deployments/999.json exists; Deploy.s.sol overwrites it and the old desks are orphaned"

echo
echo "what Ship.s.sol will do with real money"
echo "  canonical desk   $CANONICAL_BASE UBTC-raw + $CANONICAL_QUOTE USDT0-raw into a DeskAccount you own"
echo "  control          the same amounts shipped from $DEPLOYER itself, and Aqua is left an"
echo "                   unlimited approval on both real tokens so it can pull later fills."
echo "                   Use a key that holds only what you are willing to have shipped."
echo

[ "$fail" -eq 0 ] || { echo "preflight failed — nothing was sent."; exit 1; }

# `forge script` pads a gas estimate by 30%. DeskAccount's code deposit is 2 863 583 gas of a
# 3 000 000 small block, so on the deploy the padding is what does not fit; everything else keeps it.
DEPLOY="forge script script/Deploy.s.sol --rpc-url hyperevm --account $ACCOUNT --sender $DEPLOYER --broadcast --gas-estimate-multiplier 102"
SHIP="forge script script/Ship.s.sol --rpc-url hyperevm --account $ACCOUNT --sender $DEPLOYER --broadcast"
SWAP="DESK=\$(jq -r .demoDesk deployments/999.json) SELL_BASE=false AMOUNT=1000000000 forge script script/Swap.s.sol --rpc-url hyperevm --account $ACCOUNT --sender $DEPLOYER --broadcast"

if [ "$GO" = false ]; then
  echo "preflight clean. --go runs these three, in this order:"
  echo; echo "  $DEPLOY"; echo; echo "  $SHIP"; echo; echo "  $SWAP"; echo
  exit 0
fi

echo "== deploy =="; eval "$DEPLOY"
echo "== ship =="  ; eval "$SHIP"
echo "== swap ==" ; eval "$SWAP"
echo
echo "deployments/999.json:"; jq . deployments/999.json
echo "the console reads it on its next tick: ./script/appdata.sh && open app/index.html"
