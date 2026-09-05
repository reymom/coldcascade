#!/usr/bin/env bash
# The whole thing on a local fork of 999: real Aqua, real SwapVM router, mocked precompiles.
#
# The HyperCore precompiles have no bytecode, so a fork answers nothing at 0x0806 / 0x0807 /
# 0x0809 / 0x080e. anvil_setCode plants HyperCoreMock at all four and the book becomes something
# a test can move — which is the only way to see a quote respond to a book off a live node.
#
#   ./script/localnet.sh            # fork, etch, deploy, ship, swap
#   BOOK="800000 800010 799900 800200" ./script/localnet.sh  # start from a chosen book
#
# Leaves anvil running on :8545 with the console's addresses in deployments/999.json.
set -euo pipefail

RPC_UPSTREAM="${HYPEREVM_RPC_URL:-https://rpc.hyperliquid.xyz/evm}"
PORT="${PORT:-8545}"
LOCAL="http://127.0.0.1:$PORT"
# No key anywhere: anvil runs with --auto-impersonate, so the deployer is just an address and the
# node signs for it. One less secret in a script whose whole point is that anyone can run it.
DEPLOYER="${DEPLOYER:-0x00000000000000000000000000000000C01dCa5c}"

MARK=0x0000000000000000000000000000000000000806
ORACLE=0x0000000000000000000000000000000000000807
L1BLOCK=0x0000000000000000000000000000000000000809
BBO=0x000000000000000000000000000000000000080e
PERP="${PERP_INDEX:-0}"

forge build >/dev/null

echo "forking $RPC_UPSTREAM on :$PORT"
anvil --fork-url "$RPC_UPSTREAM" --port "$PORT" --auto-impersonate --silent &
ANVIL=$!
trap 'echo; echo "anvil still running as pid $ANVIL — kill it when done"' EXIT
until cast block-number --rpc-url "$LOCAL" >/dev/null 2>&1; do sleep 0.3; done
echo "forked at block $(cast block-number --rpc-url "$LOCAL"), chain $(cast chain-id --rpc-url "$LOCAL")"

# The book the fork cannot serve. One bytecode at four addresses; storage is per-address, so each
# instance is set through its own setter — exactly what the Foundry suite does with vm.etch.
CODE=$(jq -r '.deployedBytecode.object' out/HyperCoreMock.sol/HyperCoreMock.json)
for a in "$MARK" "$ORACLE" "$L1BLOCK" "$BBO"; do
  cast rpc anvil_setCode "$a" "$CODE" --rpc-url "$LOCAL" >/dev/null
done

read -r BID ASK MK OR <<<"${BOOK:-799500 799510 799510 799792}"   # 999 at block 45 109 318
cast rpc anvil_setBalance "$DEPLOYER" 0x56bc75e2d63100000 --rpc-url "$LOCAL" >/dev/null   # 100 HYPE
send() { cast send --rpc-url "$LOCAL" --unlocked --from "$DEPLOYER" "$@" >/dev/null; }
send "$BBO"     "setBbo(uint32,uint64,uint64)" "$PERP" "$BID" "$ASK"
send "$MARK"    "setPx(uint32,uint64)" "$PERP" "$MK"
send "$ORACLE"  "setPx(uint32,uint64)" "$PERP" "$OR"
send "$L1BLOCK" "setL1Block(uint64)" 1
echo "book planted: bid $BID ask $ASK mark $MK oracle $OR"

export HYPEREVM_RPC_URL="$LOCAL"
# --gas-estimate-multiplier 102: forge pads an estimate by 30% by default, and DeskAccount's
# deposit is 2 863 583 of a 3 000 000 small block, so the padding is what does not fit.
run() { forge script "$1" --rpc-url "$LOCAL" --unlocked --sender "$DEPLOYER" --gas-estimate-multiplier 102 --broadcast; }

echo; echo "== deploy =="; run script/Deploy.s.sol | grep -E "^  (wrote|.*0x)" || true
echo; echo "== ship =="; run script/Ship.s.sol | grep -E "canonical|demo |control " || true

DESK=$(jq -r .demoDesk deployments/999.json)
echo; echo "== swap: buy demo base from $DESK =="
DESK="$DESK" SELL_BASE=false AMOUNT="${AMOUNT:-1000000000}" run script/Swap.s.sol \
  | grep -E "desk bid|lean|quote in|filled in|^  0x" || true

echo
echo "deployments/999.json:"; jq . deployments/999.json
echo
echo "move the book and quote again — this is the death metric, by hand:"
echo "  cast send $BBO 'setBbo(uint32,uint64,uint64)' $PERP 810000 810010 --rpc-url $LOCAL --unlocked --from $DEPLOYER"
echo "  DESK=$DESK SELL_BASE=false AMOUNT=1000000000 forge script script/Swap.s.sol --rpc-url $LOCAL --unlocked --sender $DEPLOYER --broadcast"
