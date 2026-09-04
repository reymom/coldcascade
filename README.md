# coldcascade

A maker program on 1inch Aqua, on HyperEVM, whose quote is bounded by Hyperliquid's own book and
leans into liquidation cascades.

HyperEVM is the only chain where Aqua is deployed and a contract can read the perp book in the
same call: `0x0806` mark, `0x0807` oracle, `0x080e` best bid and ask, as precompiles. Aqua's
HyperEVM deployment has no makers. This is the first program that quotes against that book.

The program is `XYCSwap || Extruction(CoreQuote)` on the official SwapVM router. `CoreQuote`
reads the book in the quote itself. In the quiet the desk sits outside L1, so it cannot be taken
stale. When the book dislocates from oracle, or a fresh liquidation map says mark is walking into
forced flow, the absorbing side moves inside the spread and warehouses the overshoot. Makers ship
it from their own wallet; Aqua custodies nothing.

## Status

Scaffolding. Interfaces, program shape, test names. Numbers arrive when the replay runs.

## Build

```
yarn install --frozen-lockfile --ignore-scripts
forge build
forge test
```

- Foundry `nightly`. `@1inch/aqua` and `@1inch/swap-vm` resolve from GitHub at pinned commits;
  `@1inch/solidity-utils` is held at 6.9.10 through `resolutions`, because Aqua's 6.9.7 is
  missing `TransientLockUnsafe.sol`.
- HyperEVM mainnet is chain 999 (gas 0.1 gwei), testnet 998. `eth_getLogs` caps at 1000 blocks.
- **The HyperCore precompiles carry no bytecode**, so a forge fork cannot call them. Tests etch
  `test/mocks/HyperCoreMock.sol` at `0x0806` / `0x0807` / `0x080e`; live behaviour is probed on
  998 with `script/Probe.s.sol`. This is why the suite is green with skips before the probe runs.

## Prior art

- P1, arXiv:2607.27070 — no early warning exists; this is a nowcast, not a forecast.
- P2, arXiv:2608.03616 — the venue backstop absorbed most of the cascade; this is public absorber
  capacity.
- Chitra, arXiv:2512.01112 — auto-deleveraging is what happens when absorbers run out.
- Bouchaud, arXiv:1412.0141 — mechanical impact decays; the markout clock.
- 1inch Aqua and SwapVM, HumidiFi, HLP, Ballast, MEV-X: cited in the design notes to come.
