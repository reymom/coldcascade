# film — the mechanism explainer, and how to rebuild it

The 54-second film on The Cascade tab. It is here because a reader who sees an animation
like that reasonably wonders whether it was drawn or measured, and the answer should be
checkable rather than asserted.

It is measured. `scripts/tape.py` reads `../results/oct10_replay.csv` — read-only — and
writes `src/tape.ts`: bid, ask, mark, oracle, dislocation, the liquidation map and the
desk's fills, minute by minute, for 21:03 → 21:37 UTC on 10 October 2025. The film
interpolates those minutes and draws nothing it was not given.

What stays illustrative, and the film does not claim otherwise: the texture below one
minute, the oracle's own posting cadence, and the cover cadence.

## Rebuild

```
npm install
npx remotion render Mechanism out/mechanism.mp4
```

`app/mechanism.mp4` is that output. The oracle-pegged rival's losses are the same
`lvrPeggedNtl` column the replay publishes, sampled per minute — not an estimate.
