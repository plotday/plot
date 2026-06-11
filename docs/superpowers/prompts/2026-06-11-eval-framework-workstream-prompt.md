# Agent prompt: eval-framework workstream (design + implement, run to completion)

> Paste everything below this line into a fresh Claude Code session in
> `/Users/kris.braun/code/plot`.

---

You are running the **eval-framework workstream** for Plot's thread
classifier: build the evaluation infrastructure that makes classifier
optimization evidence-driven, then run the first tuning pass with it. You
run **autonomously to completion** — Kris has pre-authorized everything in
this prompt and will NOT answer questions mid-run. When you hit a genuine
fork this prompt doesn't settle, pick the option that maximizes evidence
quality, record the decision and alternatives in your final report, and
keep going. Stop early only if the environment is broken in a way you
cannot repair (then write the report explaining exactly what blocked you).

## Where things stand

Read these first (they are the source of truth for context):

- `docs/superpowers/specs/2026-06-10-classifier-signal-port-decision-log-design.md`
  and `docs/superpowers/plans/2026-06-10-classifier-signal-port-decision-log.md`
  — the just-merged predecessor workstream (merge commit `06acb759f`).
- Memory file `project_eval_classifier_review.md` (auto-memory) — phase-1
  review findings + what shipped + the deferred list this workstream executes.
- `libs/eval/` — the existing harness: corpus schema v1
  (`src/corpus/schema.ts`), transactional pg sandbox (`src/sandbox/`),
  runner/report (`src/runner/run.ts`, `src/scoring/report.ts`), classifier
  registry (`src/classifiers/registry.ts`), prod seeders (`src/seeder/`),
  corpora `kris` (80 cases / 60 gold) and `synthetic-tiny`.
- `libs/classifier/` — the production TS hybrid-LLM cascade
  (`ts:hybrid-llm:production@<paramsHash>` via
  `libs/classifier-runtime/src/factory.ts`). The scoring stage now includes
  the facet gate and connection-origin bonus (`originBonus {exact: 0.18,
  org: 0.09}` — untuned defaults). `HybridParams` lives in
  `ts-hybrid.defaults.ts`.
- `public.classification_decision` — append-only decision log (table +
  five writers shipped). **Not yet deployed to prod**, so the prod table
  is empty or absent until Kris deploys; local dev DBs have it. Build
  decision-log tooling against the local DB and make prod mining degrade
  gracefully (0 rows ⇒ informative message, not an error).

## Authorizations (pre-approved — do not re-ask)

1. **Prod read access**: yes. Use the readonly proxy
   (`pnpm prod-db-connect`, postgres on port 5433, role `readonly`;
   see the `prod-db-investigate` skill and `libs/eval/src/seeder/from-prod.ts`).
   You may extract corpora for `kris@plot.day` **plus the 2–3 most active
   other users** (by `thread_priority` row count). NEVER write to prod.
2. **Anonymization is mandatory and must be upgraded first** (deliverable B
   below) before any non-kris corpus is written to disk. Before committing
   any corpus file, run a leak check: no raw emails, contact names, or
   non-freemail real domains from the source user may appear in the YAML
   (priority/thread titles are intentionally preserved verbatim — same
   policy as today, documented in `from-prod.ts`). Never write the
   anonymization mapping itself to disk.
3. **LLM budget: generous.** `GOOGLE_GENERATIVE_AI_API_KEY` is in
   `workers/api/.dev.vars` — source it for eval runs (the eval LLM client
   reads it from the environment). Full-corpus `ts:hybrid-llm` runs,
   parameter sweeps, and LLM-proposed gold labels are all approved.
   Responses are file-cached under `libs/eval/.cache/llm/` (gitignored,
   currently empty — first runs are live). Order sweeps so cache reuse is
   maximized (sweep deterministic params against cached LLM outcomes where
   the prompt inputs don't change).
4. **End state: merge to local main.** Final integration review → merge
   into local `main` in the main checkout → verify suites on the merged
   result → clean up worktree/branch. **Never push, never deploy, never
   publish.**
5. **Out of scope** (explicitly excluded — do not build): CI workflows /
   GitHub Actions; production DB schema changes (if a deliverable seems to
   need one, redesign it eval-side and note it in the report); changes to
   production `DEFAULTS`/`DEFAULTS_LLM` (the tuning pass *proposes*, see J);
   `public/` submodule changes.

## Deliverables (priority order; A–F are core, G–J follow)

**A. Corpus schema v2** (`libs/eval/src/corpus/schema.ts` + loader + sandbox):
the world can express every signal the production classifier consumes.
Add: per-thread `facets` (format/automation/reach) and timestamps
(`created_at`, and for training threads the move time — needed for E);
per-priority `facet_filters` + `description`; `negatives` (mirror of
`thread_priority_negative`: thread refs + priority + source); connections
(`twist_instances` with owner + provider + actor contact, so
`connection_org_key` resolves and channels get real FK parents instead of
the current placeholder hack in `pg-sandbox.ts`); user `subscription` tier;
case-level `tags: string[]` and `gold_source: human | llm-proposed | null`.
`schema_version: 2` with a compatibility path for v1 corpora (upgrade
`synthetic-tiny` in place). The sandbox loader must insert all of it so the
origin signal, facet gate, negative penalty, and budget tier are genuinely
exercisable. The runner passes real `facets`/`authorContactId`/`connectionId`
to candidates from the corpus.

**B. Shape-preserving anonymization** (`src/seeder/anonymize.ts`): replace
`Person <hash>` / `c-<hash>@example.test` with deterministic realistic fake
names and a per-domain mapping that preserves domain equality and the
freemail-vs-org distinction (real freemail domains map to a fixed freemail
pool; org domains map to stable fake org domains). The LLM stages and
`connection_org_key` semantics must survive anonymization. Keep it
deterministic per source string (same inputs → same outputs across re-runs).

**C. Seeder upgrades** (`src/seeder/`):
- `from-prod` extracts everything schema v2 models (negatives, facets,
  facet_filters, descriptions, connections, subscription, timestamps).
- **Move-holdout mode**: `--holdout-recent-moves N` keeps the N most recent
  `user_moved` threads OUT of the training set and emits them as gold cases
  (gold = the move target, `gold_source: human`).
- **Decision-log mining**: a new seeder mode that turns
  `classification_decision` history into labeled cases — an auto row
  followed by a `user_move` row with a different priority is a labeled
  misclassification (note the documented asymmetry: TS rows log stage
  `none` with NULL priority, SQL trigger rows log `sql:applied` with root
  resolved — both are the "low-confidence" bucket). Works against any DB
  URL; tolerate an empty/missing table (prod until deploy).
- Multi-user: extract kris + the 2–3 most active other users into separate
  corpora.
- Refresh the kris corpus through the v2 pipeline (gold labels and case
  identity must survive re-extraction — preserve the existing `gold` /
  `gold_rationale` by case id; the existing `add-prod-*.ts` append scripts
  must keep working or be migrated).

**D. Embedding backfill**: fill the missing case/training embeddings
(currently 9 cases + 8 training threads in kris have none) by embedding the
title with the same model production uses (`bge-small-en-v1.5`, 384-dim,
title-or-preview text — see `capture.ts`). Preferred: local inference via
`@huggingface/transformers` (model `Xenova/bge-small-en-v1.5`) as an eval
devDependency. **Parity gate**: before backfilling, embed 5 texts whose
prod embeddings already exist in the corpus and verify cosine similarity
≥ 0.99 between local and prod vectors for the same text; if parity fails,
do not mix — tag backfilled vectors with a distinct ref prefix, report the
deviation, and keep them out of the sem signal unless a corpus uses them
consistently.

**E. Time-replay backtest**: evaluate the cold-start→warm trajectory. Each
case carries an `as_of` timestamp; the runner replays cases chronologically
with the training set restricted to moves that existed before each case's
`as_of` (the existing static training-set matrix stays for the old mode).
A seeder flag emits a backtest corpus from a user's real timeline.

**F. CLI ergonomics + honest statistics** (`src/cli.ts`, runner, report):
- `--params <file.json>`: deep-merge overrides onto a base variant's
  `HybridParams` (no registry edit needed for a one-off variant).
- `--sweep <spec>`: grid sweeps (e.g. `originBonus.exact=0:0.3:0.05`)
  producing a leaderboard; sweeps respect the LLM cache.
- `--save-baseline <file>` / `--baseline <file>`: per-case prediction
  snapshots; comparisons classify flips as fixed / broke / neutral
  relative to gold.
- Rank-of-gold diagnostics: per miss, the gold priority's rank and margin
  in the scoring explain; aggregates (top-3 hit rate, MRR).
- Per-tag slicing (case `tags` from A).
- Wilson 95% CI on gold accuracy; McNemar's test for paired variant
  comparisons; the report must flag differences within noise.
- LLM token/cost accounting per run (the Gemini client exposes usage —
  thread it through `ClassificationResult`/RunResult or a parallel channel).

**G. Synthetic corpora**: author 2–3 personas yourself (no API needed) in
`corpora/synthetic-*`, covering shapes the real corpora lack: facet-gate
material (newsletters/receipts/promotions vs trusted senders), multi-account
work/personal routing (exercises origin + account-hierarchy), group-heavy
worlds, ambiguous topics. Labels are by construction; embeddings via D's
local model. Keep synthetic results separated from real-data results in all
reports.

**H. Gold-label completion**: the kris corpus has ~20 unlabeled cases. Use
the LLM (or your own judgment with the world context) to propose gold
labels, written with `gold_source: llm-proposed` and a rationale — never
overwrite a human label, and report the proposed set so Kris can audit.

**I. Runbook** (`libs/eval/AGENTS.md`): the operating manual for the next
optimizing agent — how to run/seed/sweep, which metrics matter (gold
accuracy with CI, per-slice, rank-of-gold, cost), guardrails (holdout
discipline: pick ONE corpus/split as final holdout, never tune on it;
noise thresholds; cache hygiene; re-seeding rituals; decision-log mining
once prod deploys). Also fix the hygiene drift: stale
`corpora/kris/baseline-report.md` (says 30 cases) and the README's
outdated `cases/NNN-*.yaml` layout description.

**J. First tuning pass** (only after A–I are green): using the new corpora,
backtest, sweeps, and statistics, optimize `HybridParams` (weights, floors,
`originBonus`, aggregation, threshold) for gold accuracy with the holdout
discipline from I. Deliverable: a registered eval variant
`ts:hybrid-llm:tuned-2026-06` plus an evidence report (what moved, by how
much, CIs, holdout result, cost) and a PROPOSED diff to
`DEFAULTS`/`DEFAULTS_LLM` in the report — do **not** change production
defaults yourself.

## Process requirements

- Use the superpowers flow, replacing user gates with adversarial
  self-review: brainstorm briefly → write a spec to
  `docs/superpowers/specs/` → dispatch a critic subagent to attack it
  (scope, privacy, feasibility) and fix findings → write the plan to
  `docs/superpowers/plans/` (bite-sized tasks, complete code) → execute via
  `superpowers:subagent-driven-development` (fresh implementer per task,
  spec review + code-quality review per task, fix loops) → final
  whole-branch integration review → `superpowers:finishing-a-development-branch`
  with the pre-made choice: **merge to local main**.
- Work in a worktree (`superpowers:using-git-worktrees`; the native tool
  may fail to chdir with an `ENOENT ... -> '}'` error — the worktree is
  still created; `cd` into it manually and continue). Run
  `bash scripts/worktree-db` (eval needs a live DB) and from then on prefix
  EVERY DB command with the explicit
  `DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:<PORT-from-.worktree-db>/postgres"`
  — the ambient env var is stale and points at the main repo's DB, and
  subagents inherit the stale value, so put the explicit URL in every
  subagent prompt.
- Never touch the main checkout (`/Users/kris.braun/code/plot`) until the
  final merge step; never switch its branch; Kris works there concurrently.
  At merge time: merge the feature branch into `main` from the main
  checkout without pulling, re-run the eval/classifier suites on the
  merged result, then remove the worktree
  (`echo '{"path": "<worktree>"}' | bash scripts/worktree-remove`) and
  delete the branch.
- Commits end with `Co-Authored-By:` trailer per repo convention. Run
  `/finalize` before declaring done (expect: docs/updates.md NOT needed —
  this is internal infra; no public submodule changes).

## Known gotchas (hard-won this month — believe them)

- **Stale harness diagnostics**: the IDE diagnostics you receive after
  subagent work routinely reflect mid-edit states or deleted-worktree
  paths. Verify with `tsc`/tests before reacting; trust green test runs
  over red diagnostics.
- `pnpm --filter @plotday/eval eval -- ...` mangles stdout/args; run the
  CLI as `cd libs/eval && pnpm exec tsx src/cli.ts ...`. The CLI exits 1
  when there are regressions vs `expected` labels (pre-existing; `|| true`
  when capturing JSON).
- Eval vitest is `describe.runIf(!!process.env.DATABASE_URL)` — export the
  explicit URL or the DB tests silently skip.
- `workers/api` tsc shows ~120 module-not-found errors until the twister
  submodule is built (`cd public/twister && pnpm build`); they are
  pre-existing noise. You likely won't touch workers/api at all.
- pgTAP on a populated dev DB can collide with real data (known failing
  example on main's DB: `45-thread-assignee-mirror` test 3 — pre-existing,
  not yours). The worktree DB is clean; prefer it for full-suite runs.
- The existing per-task review pattern catches real bugs (this workstream's
  predecessor had a transaction-poisoning Critical caught only in review)
  — do not skip the two-stage reviews.
- Today's eval accuracy numbers for context: `ts:hybrid:default`
  (deterministic) on kris/full ≈ 33% gold; the LLM cascade is where quality
  lives. Don't panic at low deterministic numbers; do flag if a change
  makes them WORSE.

## Final report

Write `docs/superpowers/reports/2026-06-XX-eval-framework-report.md`
covering: what shipped (per deliverable), corpus inventory (sizes, gold
coverage, gold_source breakdown), baseline vs post-tuning metrics with CIs
on every corpus + the untouched holdout, the proposed HybridParams diff
with evidence, decisions made at forks, open questions for Kris (e.g.
LLM-proposed gold labels awaiting audit, anonymization spot-check), and
exact follow-up commands. Update the auto-memory file
`project_eval_classifier_review.md` (and its MEMORY.md index line) with the
end state. The report — not the chat transcript — is the artifact Kris
reads first.
