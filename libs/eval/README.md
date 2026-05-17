# @plotday/eval

Offline evaluation harness for Plot's thread → priority classifier.

Runs one or more classifier implementations (the current SQL function, SQL
variants, TS-side scorers, LLM-based) against a YAML corpus of labeled cases
and reports accuracy against hand-labeled gold targets plus regression diffs
against a baseline.

The classifier under test is the PostgreSQL function
`public.classify_thread_for_user_explain` defined in
`libs/db/schema/60-functions/classify_thread_for_user.sql`. The companion
wrapper `classify_thread_for_user` is what all production call sites use.

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
