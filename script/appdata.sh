#!/usr/bin/env bash
# Freezes what the console needs out of the build: the bytecode it plants when nothing is deployed,
# and every selector it sends.
#
# Both come from the compiled artifacts, never from a signature typed into JavaScript. `out/` is a
# build directory and is not committed, so the page cannot read it at runtime — these two files are
# the seam. Regenerate after any change to the contracts the page calls:
#
#   forge build && ./script/appdata.sh
set -euo pipefail
cd "$(dirname "$0")/.."

id() { # artifact, signature
  local v
  v=$(jq -r --arg s "$2" '.methodIdentifiers[$s] // empty' "$1")
  [ -n "$v" ] || { echo "no selector for $2 in $1" >&2; exit 1; }
  printf '0x%s' "$v"
}

PARAMS='(address,address,uint32,uint64,uint64,uint16,uint16,uint16,address,uint32,uint128,uint128,uint128)'
LENS=out/FloorLens.sol/FloorLens.json
ACCOUNT=out/DeskAccount.sol/DeskAccount.json
ROUTER=out/AquaSwapVMRouter.sol/AquaSwapVMRouter.json
TOKEN=out/DemoToken.sol/DemoToken.json
MAP=out/MapOracle.sol/MapOracle.json
FACTORY=out/DeskFactory.sol/DeskFactory.json

jq -n \
  --arg floor       "$(id $LENS    "floor(address,uint32,address[],$PARAMS[])")" \
  --arg deskAt      "$(id $LENS    "deskAt(address,address)")" \
  --arg order       "$(id $ACCOUNT 'order()')" \
  --arg params      "$(id $ACCOUNT 'params()')" \
  --arg quote       "$(id $ROUTER  'quote((address,uint256,bytes),address,address,uint256,bytes)')" \
  --arg swap        "$(id $ROUTER  'swap((address,uint256,bytes),address,address,uint256,bytes)')" \
  --arg balanceOf   "$(id $TOKEN   'balanceOf(address)')" \
  --arg allowance   "$(id $TOKEN   'allowance(address,address)')" \
  --arg approve     "$(id $TOKEN   'approve(address,uint256)')" \
  --arg mint        "$(id $TOKEN   'mint(address,uint256)')" \
  --arg decimals    "$(id $TOKEN   'decimals()')" \
  --arg symbol      "$(id $TOKEN   'symbol()')" \
  --arg update      "$(id $MAP     'update(uint32,uint128,uint128)')" \
  --arg open        "$(id $FACTORY "open(string,$PARAMS,uint256,uint256)")" \
  '$ARGS.named' > app/selectors.json

jq -n \
  --arg precompiles "$(jq -r '.deployedBytecode.object' out/CorePrecompiles.sol/CorePrecompiles.json)" \
  --arg coreQuoteCreation "$(jq -r '.bytecode.object' out/CoreQuote.sol/CoreQuote.json)" \
  --arg lens "$(jq -r '.deployedBytecode.object' out/FloorLens.sol/FloorLens.json)" \
  --arg builtAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
     builtAt: $builtAt,
     note: "Planted by eth_call state override so the Floor can quote before anything is deployed. CoreQuote is creation code: it takes its reader as a constructor argument, so its runtime is produced by running that constructor on the node.",
     corePrecompiles: $precompiles,
     coreQuoteCreation: $coreQuoteCreation,
     floorLens: $lens
   }' > app/bytecode.json

echo "app/selectors.json:"; jq -c . app/selectors.json
echo "app/bytecode.json: $(wc -c < app/bytecode.json) bytes"
