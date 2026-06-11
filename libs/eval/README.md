# @plotday/eval

Offline evaluation harness for Plot's thread → priority classifier.

Runs one or more classifier implementations (the current SQL function, SQL
variants, TS-side scorers, LLM-based) against a YAML corpus of labeled cases
and reports accuracy against hand-labeled gold targets plus regression diffs
against a baseline.

The default classifier under test is `ts:hybrid-llm:default` — the same
TS hybrid-LLM cascade production runs (`libs/classifier`, dispatched via
`workers/api` and `workers/classify`). The historical SQL classifier
`public.classify_thread_for_user` (still used inline by a few DB trigger
paths) remains available as the `sql:current` variant for comparison.

## Quick start

```bash
# Local Postgres must be running (libs/db).
pnpm --filter @plotday/eval test                  # vitest on synthetic-tiny
pnpm --filter @plotday/eval eval -- --corpus synthetic-tiny
```

## Corpus layout

```
corpora/<name>/
  world.yaml          # priority tree, contacts, training set, embeddings
  cases/NNN-*.yaml    # one labeled candidate per file
```

See `corpora/synthetic-tiny/` for a worked example.

## Adding a classifier

Implement `Classifier` from `src/classifiers/types.ts` and register it in
`src/classifiers/registry.ts`. The runner will pick it up automatically.
