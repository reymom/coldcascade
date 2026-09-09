# AI usage

ETHOnline 2026 requires each submission to document where and how AI tools were used. This is that
document, and it is meant to be read as a full answer rather than a disclaimer: which models, on
which parts of this repository, and what was done by hand instead.

AI assistance is used throughout this repository. Every model below was driven through the same
harness — **Claude Code**, used as the terminal agent for all of them, including the ones that are
not Anthropic's.

## The models, and what each one did

| model | role | where it shows up |
|---|---|---|
| **Claude Opus 5** (Anthropic) | Orchestrator and guide for the whole build, start to finish. It ran the sessions, held the plan, and did the implementation work. | Everything: `src/`, `test/`, `script/`, `keeper/`, `substreams/`, `mcp/`, `api/`, this README's prose, and the first version of the console in `app/` |
| **Claude Fable 5.1** (Anthropic) | Architecture planning at the hard points, and later a full external audit of the submission | The design passes behind `CoreQuote`, `DeskAccount`, the regime split and the keeper's shape; an end-to-end review on 9 September that produced several of the fixes in the last commits |
| **moonshotai/kimi-k3** | Refactored the console, which Opus 5 had written first, and has led the front end since | `app/` |
| **openai/gpt-6-astra-pro** | A checkpoint audit on the third day of the event | A line-by-line review of the repository and the claims in it, 7 September; several corrections to what the README asserts came from it |
| **x-ai/grok-4.6** | A further audit, focused on prize fit and on claim-checking | 8 September; the decision about which partner tracks to enter, and a pass over the numbers |

The reviews by Fable, Astra and Grok were adversarial by design: each was asked to find what was
wrong, overstated or unverifiable, and their findings were worked through rather than filed. Where
a review disagreed with the code, the code or the sentence changed.

The video and the last days before submission are not covered above; this file is updated as that
work happens rather than written once at the end.

## Commits

**Every commit in this repository was reviewed, made and pushed by hand by the author.** Models
help draft the text of a commit message; nothing is committed without being read first. There are
deliberately no `Co-Authored-By` trailers — attribution is stated here, for the repository as a
whole, rather than asserted per commit.

## What is not AI-generated

- **The mechanism.** Reading L1 inside the quote, clamping to what crossing L1 would have paid, the
  regime switch and the choice to extend SwapVM through `Extruction` rather than a modified opcode
  are the author's decisions. So is every parameter: `quietBps`, `stressBps`, the inventory band,
  the horizons and their tolerances.
- **The research the design is built on.** The three preprints on the 10 October 2025 cascade and
  the LVR literature in *Prior art* are cited, not generated; the reading of them that this desk
  attacks one channel of LVR is the author's.
- **Every transaction on chain 999.** The deployments, the ships, the fills, the hedge legs and the
  policy configuration were signed by the author with keys no model has ever held. The one
  automated signer is the hedge operator's Privy wallet, which can call `cover()` and nothing else,
  under a policy documented in the README — and that is the desk's own automation, not a model's.
- **The claims.** Every figure in the README, in `results/` and in the console was checked against
  the chain, a receipt or the primary document in the session it was written. Models drafted much
  of the prose; nothing reached it unverified.

## What was not used

No spec-driven development framework — no OpenSpec, Kiro or spec-kit. There is no `specs/`
directory because there was no such workflow, not because one was removed.
