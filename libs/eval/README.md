# @plotday/eval

Offline evaluation harness for Plot's thread → priority classifier.

Runs one or more classifier implementations (the production TS hybrid-LLM
cascade, its deterministic subset, SQL variants, ad-hoc parameter variants)
against YAML corpora of labeled cases inside a transactional Postgres
sandbox, and reports gold accuracy (with Wilson CIs), regression diffs,
parameter-sweep leaderboards, and token/cost accounting.

The default classifier under test is `ts:hybrid-llm:default` — the same
TS hybrid-LLM cascade production runs (`libs/classifier`, dispatched via
`workers/api` and `workers/classify`). The historical SQL classifier
`public.classify_thread_for_user` (still used inline by a few DB trigger
paths) remains available as the `sql:current` variant for comparison.

**Start with [AGENTS.md](./AGENTS.md)** — the operating runbook: exact
commands, corpus model, seeding rituals, statistics guardrails, LLM-cache
rules, and the corpora inventory. This README is only a map.

## Quick start

```bash
cd libs/eval
DATABASE_URL=<postgres-url> pnpm exec tsx src/cli.ts --corpus synthetic-tiny
DATABASE_URL=<postgres-url> pnpm test          # vitest (DB tests skip silently without DATABASE_URL)
```

Do NOT use `pnpm --filter @plotday/eval eval -- …` — pnpm forwards a literal
`--` positional and the CLI's parseArgs rejects it. See AGENTS.md for the
DATABASE_URL rules (worktree ports) and LLM API-key setup.

## Corpus layout (schema v2)

```
corpora/<name>/
  world.yaml          # user, subscription, teams, connections, priorities
                      #   (+ descriptions, facet_filters), contacts, groups,
                      #   channels — and optionally inline embeddings
  embeddings.yaml     # optional sibling: { embeddings: [...] } (seeders
                      #   write vectors here so world.yaml stays reviewable)
  trainings/*.yaml    # named training sets: threads, negative_threads,
                      #   negatives (one eval run = training set × classifier)
  cases.yaml          # labeled candidates: candidate shape + gold/expected
                      #   labels, tags, as_of, source_thread_id
  README.md           # provenance + re-generation command (prod corpora)
```

Schema v1 corpora still load (normalized in memory); `corpora/synthetic-tiny/`
is the minimal v2 worked example. Full field semantics: AGENTS.md §2.

## Adding a classifier

Implement the `Classifier` interface from `@plotday/classifier` and register
it in `src/classifiers/registry.ts`. The runner picks it up automatically. For
parameter variants of the hybrid cascade you usually don't need registry
edits — use `--params <file.json>` / `--sweep "<spec>"` (AGENTS.md §3).
