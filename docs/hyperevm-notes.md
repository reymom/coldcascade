# Building on HyperEVM — what the node does that no local test can see

The pins, the fragile dependency graph, opcodes as table positions, 3M-gas blocks, why `forge script` cannot send a swap here, and the precompiles that ignore the block tag and carry no bytecode.

- **Foundry is pinned to one build**, in CI and for every gas figure in this file:
  `nightly-975a456ef42ab506b8d343df5541a248798c5a27` (forge 1.4.4-nightly, 2025-11-14),
  installed with `foundryup --install nightly-975a456ef42ab506b8d343df5541a248798c5a27`. The
  suite asserts gas, and two forge builds do not report the same gas for the same bytecode — the
  rolling `nightly` is a different compiler on every run. `@1inch/aqua` and `@1inch/swap-vm`
  resolve from GitHub at **`v1.0.0` and
  `v1.0.2`, which is what is deployed on 999** — not at `main`, whose `quote` and `swap` take
  different arguments. `results/999_router_abi.md` has the selectors and how the difference
  surfaced. `@1inch/solidity-utils` is held at 6.9.10 through `resolutions`, because Aqua's 6.9.7
  is missing `TransientLockUnsafe.sol`.
- **That dependency graph is fragile and nothing else may share it.** A single `yarn add` at the
  root re-resolved it: it rewrote `@1inch/swap-vm`'s own dependency edges, installed a different
  swap-vm tree from cache, and `forge build` stopped finding `ProgramBuilder.sol` — a broken
  contract build caused by adding a JavaScript bundler. So the console's toolchain lives in
  `script/vendor/` with its own `package.json` and lockfile and cannot reach this one. If the
  contracts ever stop compiling right after an install, compare `node_modules/@1inch/swap-vm/test/utils/`
  against the tag: yarn will happily serve a cached tree that does not match the lockfile's hash.
- A SwapVM opcode is **a position in the router's own instruction table**, so `XYCSwap` is 17,
  `Salt` 20 and `Extruction` 32. `test_opcodes_matchTheRoutersOwnTable` derives all three from
  `AquaOpcodes._opcodes()` rather than trusting the constants.
- HyperEVM mainnet is chain 999 (gas 0.1 gwei), testnet 998. `eth_getLogs` caps at 1000 blocks.
- **Blocks come in two sizes and the small one is the default**: 118 of 120 sampled blocks capped
  at 3 000 000 gas, two at 30 000 000. Code deposit is 200 gas a byte, so contract size is a
  deployment constraint here — `optimizer_runs` is 200 so that `DeskAccount` fits, and the factory
  takes its implementation as an argument rather than building it. `results/999_deploy_budget.md`
  has every contract's deploy gas and what the setting costs a taker.
- **A swap cannot be sent by `forge script`.** `forge script` runs the body of `run()` in its own
  EVM to collect the transactions it will broadcast — including the ones inside
  `vm.startBroadcast()` — and that EVM is a fork, which cannot serve the HyperCore precompiles. A
  call to `0x080e` lands on an empty account, so `bounds()`, `quote()` and `swap()` revert with
  `PrecompileCallFailed` before a single transaction exists. `--skip-simulation` does not help: it
  skips the simulation of transactions already collected, not the execution that collects them.
  So `script/Swap.s.sol` is a `view` that reads the account's own state, encodes the calldata and
  **prints** the four `cast` commands — quote, mint, approve, swap. The node does serve the
  precompiles, so `cast` sends what forge cannot, and `./script/localnet.sh` runs exactly the
  lines the script prints, which is what keeps them true.
- **The precompiles ignore the block tag.** A read pinned 200 000 blocks back returns the current
  book, so there is no archive read of L1 state: `BookCache` is not a fallback, it is the only
  history there is, and a page must take its whole snapshot in one call.
- **The HyperCore precompiles carry no bytecode**, so a forge fork cannot call them and much of
  the suite is skipped until the piece it covers exists. Tests etch `test/mocks/HyperCoreMock.sol`
  at `0x0806` / `0x0807` / `0x0809` / `0x080e` instead. What only a node can answer is measured on
  998 by `./script/probe998.sh`, which needs an RPC URL and no funded key:
  `results/998_precompiles.md` has the numbers and the reasoning they support.
- A SwapVM instruction is `[opcode][uint8 length][args]`, so **one instruction carries at most
  255 bytes** and `Extruction` spends 20 of them on its target. `abi.encode(DeskParams)` is 416 and
  does not build; the packed encoding in `src/libs/DeskParams.sol` is 138 and is exact — `decode`
  rejects any other length rather than reading a short buffer as a desk with a zero inventory band.
