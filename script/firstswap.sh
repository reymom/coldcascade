#!/usr/bin/env bash
# The four calls Swap.s.sol prints, sent against the node, in order.
#
# `forge script` cannot broadcast a swap here: it collects its transactions by running run() in a
# fork, a fork has no HyperCore precompiles, and CoreQuote reverts before a transaction exists.
# The node answers them fine, so Swap.s.sol prints `cast` lines and this runs exactly those lines —
# never a hand-typed copy, which is what keeps the printed ones true.
#
#   ./script/firstswap.sh                # the demo desk, 1000 dUSDT0 in
#   DESK=0x… SELL_BASE=true AMOUNT=… ./script/firstswap.sh
#
# Each `cast send` asks for the keystore password. To answer once, non-interactively:
#   CAST_AUTH="--account $DEPLOYER_ACCOUNT --password-file /path/to/pass" ./script/firstswap.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Foundry is in ~/.foundry/bin and is not on a login shell's PATH here. Adding it is the difference
# between this script working when it is run directly and it failing with nothing on the screen.
command -v forge >/dev/null || PATH="$HOME/.foundry/bin:$PATH"
command -v forge >/dev/null || { echo "forge not found (looked in ~/.foundry/bin)" >&2; exit 1; }

[ -f .env ] && { set -a; . ./.env; set +a; }

RPC="${HYPEREVM_RPC_URL:-https://rpc.hyperliquid.xyz/evm}"
ACCOUNT="${DEPLOYER_ACCOUNT:-coldcascade-deployer}"
CHAIN=$(cast chain-id --rpc-url "$RPC")
FILE="deployments/${CHAIN}.json"
[ -f "$FILE" ] || { echo "no $FILE — nothing is deployed on chain $CHAIN"; exit 1; }

# The demo desk by default: its pair is mintable, so the first swap on a chain costs nothing but
# gas and anyone can repeat it. The canonical desk holds real inventory and has no mint step.
DESK="${DESK:-$(jq -r '.demoDesk // .canonicalDesk' "$FILE")}"
TAKER="${TAKER:-${DEPLOYER:-$(cast wallet address --account "$ACCOUNT")}}"
AUTH="${CAST_AUTH:---account $ACCOUNT}"

echo "chain $CHAIN · desk $DESK · taker $TAKER"
echo

# Keep the script's own output: when it prints no commands the reason is in there, and a version of
# this that sent stderr to /dev/null reported "no commands" for a PATH that had no forge on it.
PRINTED=$(
  DESK="$DESK" SELL_BASE="${SELL_BASE:-false}" AMOUNT="${AMOUNT:-1000000000}" TAKER="$TAKER" \
  CAST_RPC="$RPC" CAST_AUTH="$AUTH" \
  forge script script/Swap.s.sol --rpc-url "$RPC" 2>&1
)
mapfile -t CMDS < <(printf '%s\n' "$PRINTED" | sed -n 's/^  \(cast [a-z]* .*\)$/\1/p')
if [ "${#CMDS[@]}" -lt 3 ]; then
  echo "Swap.s.sol printed no commands. What it did print:" >&2
  printf '%s\n' "$PRINTED" >&2
  exit 1
fi

HASH=""
for c in "${CMDS[@]}"; do
  echo "\$ $(echo "$c" | cut -c1-96)…"
  out=$(eval "$c")
  case "$c" in
    cast\ call*)
      # The quote: amountIn, amountOut, and the strategy hash the router dispatched.
      cast abi-decode 'quote()(uint256,uint256,bytes32)' "$out" | sed 's/^/    /'
      ;;
    *)
      echo "$out" | grep -E "^(transactionHash|status|blockNumber|gasUsed)" | tr -s ' ' | sed 's/^/    /'
      HASH=$(echo "$out" | awk '/^transactionHash/ { print $2 }')
      ;;
  esac
  echo
done

echo "swap $HASH"
echo "https://hyperevmscan.io/tx/$HASH"
