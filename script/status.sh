#!/usr/bin/env bash
# One screen: is anything broken, and where.
#
# Read-only. It sends nothing, signs nothing, and needs no keystore password — every number comes
# from a chain read, a local log, or an HTTP GET. Safe to run at any time, including mid-cadence.
#
# Two rules it keeps everywhere, both learned the hard way on 9 Sep:
#
#   * **Every chain read tries two endpoints.** rpc.hypurrscan.io went dark for fourteen minutes
#     that morning and a script with one endpoint died where it stood.
#   * **A failed read prints "unreadable", never a zero.** The monitor this replaces did
#     `|| echo 0` and then compared 0 against a low-balance floor, announcing an empty wallet that
#     held 0.128 HYPE. An unknown is not a value.
#
#   ./script/status.sh
#   ./script/status.sh --brief    # the same verdict as one line, for a watcher
set -uo pipefail
cd "$(dirname "$0")/.."

command -v cast >/dev/null || PATH="$HOME/.foundry/bin:$PATH"
command -v cast >/dev/null || { echo "cast not found (looked in ~/.foundry/bin)" >&2; exit 1; }

if [ -f .env ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; *=*) ;; *) continue ;; esac
    key=${line%%=*}; [ -n "${!key+set}" ] || export "$key=${line#*=}"
  done < .env
fi

A="${STATUS_RPC_A:-https://rpc.hyperliquid.xyz/evm}"
B="${STATUS_RPC_B:-https://rpc.hypurrscan.io}"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT

# Each read races nothing and retries once on the other endpoint. Written to a file so the whole
# set can be fired in parallel: eleven sequential round trips is thirty seconds, in parallel it is
# two, and a status command nobody waits for is a status command nobody runs.
two() {                                   # two <outfile> <cast args...>
  local out f="$1"; shift
  if out=$(timeout 6 cast "$@" --rpc-url "$A" 2>/dev/null) && [ -n "$out" ]; then printf '%s' "$out" >"$f"; return; fi
  if out=$(timeout 6 cast "$@" --rpc-url "$B" 2>/dev/null) && [ -n "$out" ]; then printf '%s' "$out" >"$f"; return; fi
  : >"$f"                                 # empty means unreadable, and stays empty
}

BOOKCACHE=0x24496697E43dE61af09561fb414cb909C1635533
POKER=0xA959c7A9F2B47Cc9bC2d33bBFedfA271F61E9a01
TAKER=0x7D338ecF8dC1435F96c97e2A582283Ae729a9C11
POSTER=0xfe156a611F84D36B6a697a77C0295A00Fbc14169
HEDGED=0xB4ad3Fc0702145fB7a1DE72576968f9A30987a7f
OPDESK=0xa09765E0bBC38E1Ae37f1EB9f2D75b4cEd4dc144

two "$D/head"    block-number &
two "$D/poked"   call "$BOOKCACHE" 'pokedAt(uint32)(uint64)' 0 &
two "$D/mark"    call 0x0000000000000000000000000000000000000806 "$(cast abi-encode 'f(uint32)' 0)" &
two "$D/bal.poker"  balance "$POKER"  &
two "$D/bal.taker"  balance "$TAKER"  &
two "$D/bal.poster" balance "$POSTER" &
two "$D/op"      call "$OPDESK" 'hedgeOperator()(address)' &
for d in "$HEDGED" "$OPDESK"; do
  two "$D/pos.$d" call 0x0000000000000000000000000000000000000800 "$(cast abi-encode 'f(address,uint16)' "$d" 0)" &
  two "$D/mrg.$d" call 0x000000000000000000000000000000000000080f "$(cast abi-encode 'f(uint32,address)' 0 "$d")" &
done
# The deployed artifact, which is the only thing here that is not on chain or on disk.
( timeout 6 curl -sS "https://coldcascade.vercel.app/results/markouts.json" -o "$D/deployed.json" 2>/dev/null || : ) &
wait

OPERATOR=$(cat "$D/op" 2>/dev/null | tr -d '\n')
[ -n "$OPERATOR" ] && two "$D/bal.operator" balance "$OPERATOR"

python3 script/status_render.py "$D" "$HEDGED" "$OPDESK" "$OPERATOR" ${1:+"$1"}
