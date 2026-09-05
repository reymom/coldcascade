# deployments

One file per chain, written by `script/Deploy.s.sol` and extended by `script/Ship.s.sol`. The
console reads `deployments/<chainId>.json` and, when there is none, falls back to quoting the
canonical parameters against the live book with nothing deployed — see `app/README.md`.

`31337.json` is what `script/localnet.sh` writes on a fork and is not committed: the fork keeps
999's Aqua and router but its own addresses for everything else, and an address book that mixes the
two would be worse than none.
