#!/usr/bin/env bash
# Measures the HyperCore precompiles on a live node and prints the table in results/.
#
# It needs no deployment, no funded key and no faucet: Probe's runtime bytecode is planted at a
# throwaway address through an eth_call state override, so the code that runs is the code in
# src/Probe.sol and the node that answers is a real one. A forge fork cannot do this — the
# precompiles carry no bytecode, so revm returns empty data for every one of them.
#
#   forge build && ./script/probe998.sh [rpc-url]
set -euo pipefail

RPC="${1:-${HYPERTESTNET_RPC_URL:-https://rpc.hyperliquid-testnet.xyz/evm}}"
AT=0x00000000000000000000000000000000C01dCa5c
CODE=$(jq -r '.deployedBytecode.object' out/Probe.sol/Probe.json)

rpc() { # method, params
  curl -sS -X POST "$RPC" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"
}
probe() { # calldata -> 0x… or the node's error
  rpc eth_call "[{\"to\":\"$AT\",\"data\":\"$1\",\"gas\":\"0x2faf080\"},\"latest\",{\"$AT\":{\"code\":\"$CODE\"}}]" \
    | jq -r '.result // ("ERROR: " + .error.message)'
}
word() { printf '%d\n' "0x${1:2+64*$2:64}"; }

CHAIN=$(printf '%d' "$(rpc eth_chainId '[]' | jq -r .result)")
BLOCK=$(printf '%d' "$(rpc eth_blockNumber '[]' | jq -r .result)")
echo "chain $CHAIN, block $BLOCK, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

for fn in direct nested; do
  R=$(probe "$(cast calldata "${fn}(uint32)" "${PERP:-0}")")
  case "$R" in
    0x*) printf '%-8s bid %-10s ask %-10s gas %s\n' "$fn" "$(word "$R" 0)" "$(word "$R" 1)" "$(word "$R" 2)" ;;
    *)   printf '%-8s %s\n' "$fn" "$R" ;;
  esac
done

echo
echo "one precompile frame, 5,000,000 forwarded:"
frame() { # name, address, input length, word
  R=$(probe "$(cast calldata "frame(address,uint256,uint256,uint256)" "$2" "$3" "$4" 5000000)")
  case "$R" in
    0x*) printf '  %-28s ok %-3s gas %-8s returns %s bytes\n' \
           "$1" "$(word "$R" 0)" "$(word "$R" 1)" "$(word "$R" 2)" ;;
    *)   printf '  %-28s %s\n' "$1" "$R" ;;
  esac
}
frame "0x0806 markPx(0)"        0x0000000000000000000000000000000000000806 32 0
frame "0x0807 oraclePx(0)"      0x0000000000000000000000000000000000000807 32 0
frame "0x0809 l1BlockNumber()"  0x0000000000000000000000000000000000000809  0 0
frame "0x080a perpAssetInfo(0)" 0x000000000000000000000000000000000000080a 32 0
frame "0x080e bbo(0)"           0x000000000000000000000000000000000000080e 32 0
echo
echo "the same reads under PRECOMPILE_GAS_CAP:"
CAP=$(grep -oE 'PRECOMPILE_GAS_CAP = [0-9_]+' src/libs/HyperCore.sol | grep -oE '[0-9_]+$' | tr -d _)
echo "  cap = $CAP"
capframe() {
  R=$(probe "$(cast calldata "frame(address,uint256,uint256,uint256)" "$2" "$3" "$4" "$CAP")")
  case "$R" in
    0x*) printf '  %-28s ok %-3s gas %-8s returns %s bytes\n' \
           "$1" "$(word "$R" 0)" "$(word "$R" 1)" "$(word "$R" 2)" ;;
    *)   printf '  %-28s %s\n' "$1" "$R" ;;
  esac
}
capframe "0x080a perpAssetInfo(0)" 0x000000000000000000000000000000000000080a 32 0
capframe "0x080e bbo(0)"           0x000000000000000000000000000000000000080e 32 0
capframe "0x080e bbo(99999)"       0x000000000000000000000000000000000000080e 32 99999
capframe "0x080e 4-byte input"     0x000000000000000000000000000000000000080e  4 0

echo
echo "bad input, under a cap:"
for cap in 5000 30000 200000; do
  R=$(probe "$(cast calldata "badInput(uint256)" "$cap")")
  case "$R" in
    0x*) printf '  cap %-8s succeeded %-3s burned %s\n' "$cap" "$(word "$R" 0)" "$(word "$R" 1)" ;;
    *)   printf '  cap %-8s %s\n' "$cap" "$R" ;;
  esac
done
