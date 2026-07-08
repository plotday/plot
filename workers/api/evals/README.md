# Twist generation eval harness

Measures the spec→twist generation pipeline (`generateTwist()` +
twist-builder container) against a fixed corpus of natural-language specs.
Run it before/after any change to the generation prompt, retry policy,
model, or `@plotday/twister` release, and compare.

Spec: `docs/superpowers/specs/2026-07-07-twist-generation-eval-harness-design.md`.

## Prerequisites

- Docker running (the twist-builder container is built and booted locally).
- `workers/api/.dev.vars` with `ANTHROPIC_API_KEY`, `AI_GATEWAY_ACCOUNT_ID`,
  `AI_GATEWAY_ID`, `AI_GATEWAY_TOKEN` (`pnpm --filter @plotday/api get-env`,
  or `pnpm cp-env <main-repo>` in a worktree).
- Built SDK types: `cd public/twister && pnpm build`.

## Usage

```bash
# Full corpus (≈$2–5 in API tokens, 15–30 min):
pnpm --filter @plotday/api eval:twist-gen

# One spec (≈$0.15–0.40):
pnpm --filter @plotday/api eval:twist-gen --only hello-thread

# A/B a model, then compare:
pnpm --filter @plotday/api eval:twist-gen --label baseline
pnpm --filter @plotday/api eval:twist-gen --model claude-opus-4-8 \
  --compare evals/results/<baseline-file>.json
```

Flags: `--only <ids|categories>` · `--model <id>` · `--runs <n>` ·
`--concurrency <n>` (default 3) · `--label <name>` · `--compare <json>` ·
`--keep-output` (save generated sources) · `--list`.

Results land in `evals/results/<stamp>-<label>.json` (gitignored). Exit code
0 = run completed (failing specs are data); 1 = infra problem.

## Pass bar (per spec)

1. `generateTwist()` resolves (pipeline).
2. `index.ts` default-exports a class extending `Twist` (universal).
3. Frontmatter `assertions`/`notMatch` regexes hold (per-spec).
4. `tsc --noEmit` against the real twister types passes (typecheck).

## Adding a spec

Add `evals/corpus/NN-your-id.md` with YAML frontmatter (`id`, `category`,
`difficulty`, `assertions`, optional `notMatch`/`allowDeps`) and a body
written the way a real user would describe the twist — plain language, no
SDK identifiers. `pnpm --filter @plotday/api test -- evals/__tests__/corpus.test.ts`
validates it (update the expected count).

## Caveats

- A timed-out spec's container build may still be running in the background;
  it only skews that one measurement.
- Cost figures are estimates from a hardcoded rate table in `lib/report.ts`.
