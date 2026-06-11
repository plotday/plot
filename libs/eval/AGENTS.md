# libs/eval — Classifier Eval Runbook

Operating manual for running, seeding, and tuning Plot's thread → priority
classifier evals. Written for an agent with zero prior context. The design
rationale lives in `docs/superpowers/specs/2026-06-11-eval-framework-design.md`;
this file is the *how*.

The harness runs classifier implementations (the production TS hybrid-LLM
cascade from `libs/classifier`, its deterministic subset, the legacy SQL
function, and ad-hoc parameter variants) against YAML corpora inside a
transactional Postgres sandbox: one transaction per run, a savepoint per
case, rolled back at the end. **Nothing persists in the database** — it only
needs the Plot schema (migrations applied).

## 1. Quick start

### Database

Every eval run and every DB-backed test needs a Postgres with the Plot
schema. URL resolution order (`src/sandbox/resolve-db-url.ts`):

1. `$DATABASE_URL` if set,
2. else the repo root's `.worktree-db` `PORT` (worktree-isolated DB),
3. else the main repo default `127.0.0.1:54322`.

**Do not trust the ambient `$DATABASE_URL`** — in a worktree session it
often still points at the main repo's `54322` DB (the env is captured at
session start; see the repo AGENTS.md "Stale `$DATABASE_URL`"). Set it
explicitly from `.worktree-db`:

```bash
cd libs/eval
source ../../.worktree-db    # defines PORT (worktree-isolated Postgres)
export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
```

The CLI would fall back to `.worktree-db` on its own when `$DATABASE_URL` is
unset, but **vitest will not**: every DB suite is gated with
`describe.runIf(!!process.env.DATABASE_URL)` and **silently skips** without
it. A green `pnpm test` without `DATABASE_URL` proves almost nothing — with
the DB the suite is 27 files / 342 tests.

### Running an eval

```bash
cd libs/eval
pnpm exec tsx src/cli.ts --corpus kris --classifiers ts:hybrid-llm:default --training-sets full
```

- **NEVER use `pnpm --filter @plotday/eval eval -- …`** — pnpm forwards a
  literal `--` positional and the CLI's `parseArgs` dies with
  `ERR_PARSE_ARGS_UNEXPECTED_POSITIONAL`. Always `cd libs/eval && pnpm exec
  tsx src/cli.ts …`.
- `--help` prints all flags; `--corpus <name>` resolves under
  `libs/eval/corpora/`, `--corpus-dir <path>` takes an absolute path.

### LLM API key

`ts:hybrid-llm:*` variants and `propose-gold` call Gemini on cache misses.
The key comes from `GOOGLE_GENERATIVE_AI_API_KEY` (or `GEMINI_API_KEY`):

```bash
export GOOGLE_GENERATIVE_AI_API_KEY=$(grep '^GOOGLE_GENERATIVE_AI_API_KEY=' ../../workers/api/.dev.vars | cut -d= -f2)
```

Fully-cached runs (e.g. re-running a config that already ran) never hit the
API, but the client constructor requires the key as soon as an LLM variant
is instantiated — export it for any `ts:hybrid-llm:*` run.

### Exit codes

- `0` — clean.
- `1` — at least one **expected-label regression** (the prediction disagrees
  with the `expected` label, i.e. the prod filing at extraction time) — or
  an unhandled error. Regressions are normal during tuning, so when
  capturing output append `|| true`:

  ```bash
  pnpm exec tsx src/cli.ts --corpus kris --format json > out.json || true
  ```

- `2` — usage error (bad flags, bad baseline file, sweep typo).

### Tests and lint

```bash
DATABASE_URL=... pnpm test     # vitest; 342 tests with a DB, far fewer without
pnpm lint                      # tsc + eslint
```

## 2. Corpus model (schema v2)

```
corpora/<name>/
  world.yaml          # user, subscription, teams, connections, priorities,
                      #   contacts, groups, channels (+ optional inline embeddings)
  embeddings.yaml     # optional sibling { embeddings: [...] } — seeders write
                      #   vectors here so world.yaml stays reviewable
  trainings/*.yaml    # named training sets (threads, negative_threads, negatives)
  cases.yaml          # labeled candidates
  README.md           # provenance + exact re-generation command (prod corpora)
```

Zod schemas: `src/corpus/schema.ts`. Loader (slug→UUID resolution,
embeddings merge, v1 normalization): `src/corpus/load.ts`.
`corpora/synthetic-tiny/` is the minimal worked example.

### The signal surface (world.yaml)

v2 exists so that **every signal the production classifier consumes is
expressible**:

- **`connections`** (`slug`, `id`, `provider`, `account_contact`, `team`)
  materialize as synthetic twist + `twist_instance` +
  `twist_instance_connection` rows, so `public.connection_org_key()`
  resolves exactly as in prod: non-freemail actor-email domain →
  `domain:<d>`, else team → `team:<id>`, else NULL. This drives the
  origin-bonus signal.
- **`priorities`** carry `description` and `facet_filters` (free-form jsonb
  passthrough) — the facet gate is live in eval.
- **`user.subscription`** (`{plan, status}` or null = free) reaches the
  budget tier.
- **`channels`** must reference a declared connection in v2 (real FK
  parent); `default_priority_id` drives the channel-default stage.
- **`teams`** exist only to exercise the `team:` org-key branch.
- **`contacts`** carry `name` (rendered into LLM prompts in v2) and
  `linked_to_user`.

### Threads (training sets and candidates)

- `author` (contact ref) → `thread.author_id`.
- `connection` (connection ref) → `thread.created_by` + `thread.twist_id`
  (prod semantics: connector-created threads have the twist_instance in
  `created_by`). When absent, `created_by` = the world user (self-authored).
- `created_by_override` — handcrafted **escape hatch** that sets
  `thread.created_by` to an arbitrary uuid, taking precedence over
  `connection`. v1 corpora use it internally (v1's `author` wrote
  `created_by`); v2 documents should rarely need it.
- `facets` (e.g. `{format: message, automation: automated}`) feed the facet
  gate.
- Training threads: `filed_to_priority`, `created_at` (arrival), `moved_at`
  (when the user filed it — the backtest clock).
- `negative_threads` exist only as negative evidence (no filing);
  `negatives` mirror `thread_priority_negative` rows
  (`{thread, priority, source: moved_out|deselected, created_at}`).
  Negatives are **per training set** so the training-set matrix stays
  coherent.

### Cases (cases.yaml)

- `source_thread_id` — the full prod thread uuid. Authoritative for
  refresh re-hydration and the self-exclusion guard. Older cases fall back
  to the 8-hex prefix embedded in the case id (`NNN-<8hex>`).
- `tags` — free-form slice labels (`holdout-move`, `decision-log`, …);
  reports break out gold accuracy per tag, and `--exclude-tags`/
  `--include-holdout` filter on them.
- `as_of` — the runner-side backtest clock (the staged row's `created_at`
  is clobbered by a DB trigger, so the clock lives in the corpus).
- `labels.gold` vs `labels.expected`: **gold** is the ground-truth label
  (what *should* happen); **expected** is the prod filing recorded at
  extraction time (regression tracking — disagreements drive exit code 1
  but are not correctness verdicts). `gold_rationale` is free text.
- `labels.gold_source`: `human` | `llm-proposed` | null. When `gold` is set
  and the field is **absent**, the loader backfills `human` (all pre-v2
  labels were Kris's). `llm-proposed` labels come from `propose-gold` and
  are sliced separately in every report (circularity guard — same model
  family judges and classifies).
- `expected_stage` is a free string (the v1 enum predates TS stage names
  like `llm_tiebreaker`).

### Embeddings

`{ref, vector[384], source}` where `source` ∈ `thread-title` (prod
`thread.embedding`), `note-content` (prod note-embedding fallback —
**private message bodies**, kris-only by policy), `local-title`
(locally-computed backfill, `embl-` ref prefix), or null (legacy v1).
Duplicate refs across world.yaml + embeddings.yaml are rejected at load.

### v1 compatibility

`schema_version: 1` documents still load: `author` → `created_by_override`
(old semantics preserved), all v2 fields get inert defaults, contact names
are NOT inserted (names change LLM prompts and cache keys), channels keep
the placeholder-parent hack and conflict-tolerant insert. This is pinned by
a byte-exact regression gate (`tests/regression-v1.test.ts` against the
frozen `tests/fixtures/kris-v1/` snapshot). Don't edit that fixture.

## 3. Running evals

### Classifier registry

```bash
pnpm exec tsx src/cli.ts --list-classifiers
```

Registered (`src/classifiers/registry.ts`):

| Name | What |
| --- | --- |
| `ts:hybrid-llm:default` | Production LLM cascade, prod `DEFAULTS_LLM` (model `gemini-3-flash-preview`). **CLI default.** |
| `ts:hybrid:default` | Deterministic cascade (no LLM stages), prod `DEFAULTS`. Cheap proxy for broad sweeps. |
| `ts:hybrid-llm:tight-gates` | LLM cascade with `highConfidenceFloor: 0.55`, `marginFloor: 0.12`. |
| `sql:current` | Legacy `public.classify_thread_for_user` (still on some DB trigger paths). |

Every eval-registered LLM variant gets an **unlimited budget gate** — the
production per-user counters (free tier 5000/month, 100/day) would silently
degrade long sweeps to deterministic scoring mid-run.

### Ad-hoc variants: `--params` / `--base`

```bash
echo '{"originBonus": {"exact": 0.25}}' > /tmp/p.json
pnpm exec tsx src/cli.ts --corpus kris --params /tmp/p.json --base ts:hybrid-llm:default
```

Deep-merges the JSON onto the base's `HybridParams` (objects merge,
arrays/primitives replace) and registers `<base>+params@<hash>` for this
run, appended to the classifier list. Unknown **top-level** keys are
rejected at parse time (typo guard); nested keys are not validated.
`--base` defaults to `ts:hybrid-llm:default`; `--base` alone (without
`--params`/`--sweep`) is an error. Partial `weights` overrides that break
sum-to-1 throw (`assertValidWeights`).

### Grid sweeps: `--sweep`

```bash
pnpm exec tsx src/cli.ts --corpus kris --training-sets full \
  --sweep "originBonus.exact=0:0.3:0.05;aggregation.mode=top1|softmax" \
  --base ts:hybrid:default
```

Grammar: `;`-separated dimensions, each `path=values` where values are an
**inclusive** numeric range `start:end:step` or a `|`-separated list
(numbers/booleans parse, anything else is a string). Dimensions
cross-product. Mutually exclusive with `--params` and `--classifiers`
(use `--base`).

- **`weights.<component>` renormalizes**: the swept component is set and the
  remaining components are rescaled so the sum stays 1. At most ONE
  `weights.*` dimension per spec; values must be in `[0, 1)`.
- Typos fail at **parse time** (top-level key validated against
  `HybridParams`) — before any classification runs.
- Output is a leaderboard: gold accuracy + Wilson 95% CI per point,
  fixed/broke counts and exact McNemar p **paired against the base row**
  (marked `*`), live token sums per point. `~noise` = p ≥ 0.05.

### Baselines: `--save-baseline` / `--baseline`

```bash
pnpm exec tsx src/cli.ts --corpus kris --classifiers ts:hybrid-llm:default \
  --training-sets full --save-baseline baselines/kris-v2-llm-default.json || true

pnpm exec tsx src/cli.ts --corpus kris --classifiers ts:hybrid-llm:default \
  --training-sets full --baseline baselines/kris-v2-llm-default.json || true
```

- `--save-baseline` snapshots per-case `{predicted, stage}` for **exactly
  one** (classifier, training set) combo; mutually exclusive with `--sweep`
  and `--backtest`.
- `--baseline` classifies each case as `fixed` (was ≠ gold, now = gold),
  `broke` (was = gold, now ≠ gold), changed-neutral, or same, and prints an
  exact McNemar p over the fixed/broke counts.
- **Gold is read from the CURRENT corpus**, not the snapshot — re-labeled
  cases are judged against the new gold. Check `meta.createdAt` for
  staleness.
- Saved snapshots live in `baselines/` (kris det+llm, prod-u2 det,
  prod-u3 det — all `full`, saved 2026-06-11 pre-tuning).

### Time replay: `--backtest`

```bash
pnpm exec tsx src/cli.ts --corpus kris --classifiers ts:hybrid:default \
  --backtest --training-sets full || true
```

Replays ONE training set (default `full`) chronologically: cases sort by
`as_of`; training threads insert progressively once `moved_at <= as_of`
(negatives by their own `created_at`), so each case sees only the history
that existed at its time — the cold-start→warm trajectory. Cases without
`as_of` are **skipped with a counted warning**; training threads without
`moved_at` are always present (counted note). The report adds a
training-size trajectory table (buckets 0 / 1–5 / 6–15 / 16–30 / 31+).
Mutually exclusive with `--save-baseline` (a backtest result depends on
each case's timeline position — not comparable to a matrix snapshot).

### Holdout filtering: `--exclude-tags` / `--include-holdout`

Cases tagged `holdout-move` are **excluded from every run by default** —
routine runs and sweeps cannot touch the holdout. `--include-holdout` is
the ONLY path in. **Never pass it during tuning**; it exists solely for the
single, final, pre-registered holdout evaluation (§5) — and for `prod-u3`,
whose holdout-move cases are explicitly designated tuning data (§9).
`--exclude-tags a,b` appends more excluded tags on top of the default.

### Self-exclusion guard (always on)

A case whose source thread is also in the training set would score sem≈1.0
against its own copy — a leaked answer. At each case's savepoint the runner
archives the matching training thread (matched by `source_thread_id`, or
the 8-hex case-id prefix as fallback) so it's invisible **for that case
only**. The console report prints
`Self-exclusions: N case(s) had their source thread archived…` — on
kris/full that's currently 15. This is an anti-leakage guard, not an error.

## 4. Reading reports

`--format console` (default), `json` (clean stdout; warnings go to stderr),
`markdown`.

- **Gold acc [95% CI]** — accuracy over gold-labeled cases with a Wilson
  interval. The CI is the honesty device: on ~80 cases it is ±10pp wide.
- **Expected acc / Regress** — agreement with the prod filing at extraction
  time. Regressions drive exit code 1; they are change-tracking, not
  correctness.
- **McNemar p / `~noise`** — paired exact test on discordant (fixed/broke)
  counts vs the base (sweeps) or snapshot (`--baseline`). `~noise` = p ≥
  0.05: treat the difference as unproven.
- **Rank of gold** — for cases where the scoring stage produced a ranking:
  top-3 hit rate and MRR, plus `unranked=N` (cases decided by stages that
  never rank — topic shortcircuit, channel default, …). A high unranked
  count means scoring-param sweeps can only move a minority of cases.
- **Per-tag slices** and **per-gold_source slices** (human vs llm-proposed)
  — the latter renders only when both kinds exist; a big human/llm gap
  means don't trust the llm-proposed slice for decisions.
- **LLM tokens & estimated cost** — `live` = cache misses (what the run
  actually spent), `replayed` = cache hits, `unknown` = cache entries
  predating usage capture. Cost comes from `src/scoring/cost.ts`
  `MODEL_COSTS` (hand-maintained estimates, dated 2026-06 — **check
  staleness before quoting dollar figures**; unknown models render "(cost
  unknown)", never $0).
- **`WARNING: LLM budget exhausted…`** — should NEVER appear: eval injects
  an unlimited budget gate. If you see it, something is broken (a variant
  was constructed without the eval gate); results in that run are suspect.
- **`WARNING: synthetic corpus (handcrafted)…`** — synthetic and real-data
  results must NEVER be pooled into one accuracy figure. Provenance comes
  from `world.source.kind`.

## 5. Statistics guardrails (binding)

From the design spec §J — these are rules, not suggestions:

1. With ~60–80 gold cases, McNemar at α=0.05 needs roughly a **6–0 or 8–1
   discordant split** (7–1 gives p≈0.07 — not significant). Small nudges
   are individually unfalsifiable.
2. A large grid produces ~5% false "significant" flags by multiplicity.
   **Sweeps are exploratory**; the final report must state the number of
   comparisons run.
3. **Pre-register at most 3 candidate configs** (from the tuning surface)
   *before* ANY holdout run.
4. The final paired McNemar test **pools all real-data corpora** (kris +
   prod-u3 tuning cases; never synthetics) to maximize n.
5. The holdout (kris's 12 `holdout-move` cases + the entire `prod-u2`
   corpus) is evaluated **exactly once**, at the end. At ~10–25 cases it is
   a **directional sanity check**, not a significance test — say so in the
   report.
6. **"No change proposed" is a first-class outcome.** If nothing clears the
   noise band, the evidence report says so and production defaults stand.

## 6. LLM cache honesty

The file cache lives in `.cache/llm/<namespace>/` (gitignored; namespace
`default` for classifiers, `propose-gold` for the labeler). The key is
sha256 over (model id, prompt template id, system prompt, user prompt,
sorted allowed-priority ids) — so a cache hit requires the **prompt content**
to be identical.

| Cache-stable (reuse hits well) | Cache-busting (live calls per point) |
| --- | --- |
| `highConfidenceFloor`, `marginFloor`, `supportingFloor`, `scoreThreshold`, `budget*` — they gate WHETHER an LLM stage fires, not what it sees | `weights.*`, `originBonus.*`, `negativePenaltyWeight`, `accountHierarchyBonusWeight`, `aggregation.k` — they reorder scoring, changing the tiebreaker prompt's candidate set/exemplars |

Consequences:

- **Broad grids over ranking params run the deterministic `ts:hybrid`
  base** (`--base ts:hybrid:default`) — a cheap, clearly-labeled proxy.
  Only floor/threshold sweeps and the shortlisted configs get full
  `ts:hybrid-llm` runs.
- A full kris/full LLM run is ~70–90 LLM calls when cold. **Wiping
  `.cache/llm` re-spends all of that per corpus-run** — there is almost
  never a reason to wipe: prompt-template changes get new `promptId`s
  (new keys), and stale entries are simply never hit again. Wipe only on
  suspected cache corruption.
- Cache hit rate is printed per run (`Hit%`). A re-run of an
  already-evaluated config should show ~100%; a surprising miss rate means
  prompt content changed — investigate before burning tokens.

## 7. Seeding rituals

All seeders need the prod readonly proxy (`pnpm prod-db-connect` at repo
root; default URL `postgres://readonly@127.0.0.1:5433/plot`, overridable
via `--db-url` / `$PROD_DB_URL`). Prod access is read-only; seeders only
write YAML under `corpora/`.

### Refresh a corpus, preserving labels (`from-prod`)

```bash
pnpm exec tsx src/seeder/from-prod.ts --user-email kris@plot.day --out kris \
  --case-count 80 --holdout-recent-moves 12
```

- Every existing case is **re-hydrated by `source_thread_id`** (fallback:
  the 8-hex case-id prefix, with multi-match prefixes disambiguated by
  exact candidate-title equality; unresolvable cases kept verbatim and
  reported). `gold`, `gold_rationale`, `gold_source`, `expected*`, `tags`,
  `notes` survive **byte-for-byte**; the candidate upgrades to current prod
  state. New cases are sampled to top up to `--case-count`.
- **Slug migration**: contact slugs derive from anonymized emails, so a
  refresh rewrites slug refs in every emitted file AND in extra training
  files it does not regenerate (e.g. kris's `trainings/first-day.yaml`).
- **Stale labels**: a gold/expected label pointing at a priority no longer
  active in prod is nulled, with an explanatory line appended to the case's
  `notes` and a summary count printed.
- `--holdout-recent-moves N`: the N most recent user-moved threads are
  dropped from `trainings/full.yaml` entirely and emitted as gold cases
  tagged `holdout-move` (excluded from runs by default).
- `--timeline-cases N`: sample N cases spread evenly over `thread.created_at`
  instead of stratified topic-shape sampling — for backtest-oriented corpora.

### Multi-user corpora

```bash
pnpm exec tsx src/seeder/from-prod.ts --list-active-users   # ids + counts ONLY, never emails
pnpm exec tsx src/seeder/from-prod.ts --user-id <uuid> --out prod-uN \
  --case-count 60 --holdout-recent-moves 10
```

Privacy: non-kris corpora contain **zero raw identity** (READMEs/
descriptions reference only the anonymized email) and **no `note-content`
embeddings** (they embed private message bodies; kris-only, own data).

### Appending curated threads

```bash
pnpm exec tsx src/seeder/add-prod-cases.ts     --corpus kris --threads <uuid>,<uuid>
pnpm exec tsx src/seeder/add-prod-trainings.ts --corpus kris --set full --threads <uuid>
```

Hydrate + anonymize specific prod threads into an existing **v2** corpus;
newly-referenced contacts/groups/connections/embeddings are backfilled into
world.yaml / embeddings.yaml; everything existing is preserved.

### Decision-log mining (`from-decision-log`)

```bash
pnpm exec tsx src/seeder/from-decision-log.ts --corpus kris [--db-url <url>]
```

Mines `classification_decision`: per thread, the LATEST `user_move` paired
with the latest earlier auto decision; when the priorities differ it's a
labeled misclassification — **gold = the user's final move**
(`gold_source: human`, tag `decision-log`), expected = the auto choice,
`as_of` = the auto decision's time. A missing/empty table (prod until the
decision-log deploy ships) prints an informative message and exits 0 — so
"it did nothing" before the deploy is correct behavior.

### LLM gold proposals (`propose-gold`)

```bash
pnpm exec tsx src/seeder/propose-gold.ts --corpus kris
```

Fills `gold: null` cases only — **human labels are never overwritten and no
`--force` exists**. Writes `gold_source: llm-proposed` and a `[llm]`-prefixed
rationale; prints every proposal as an audit table. Uses its own promptId
(`propose-gold-v1`) and cache namespace so it cannot collide with classifier
caches. Policy: run on **kris only** (Kris audits the proposals); prod-u2/u3
unlabeled cases stay unlabeled.

### Embedding backfill (`gen-embeddings`)

```bash
pnpm exec tsx src/seeder/gen-embeddings.ts --corpus <name> [--parity-only]
```

- Fills `embedding_ref: null` entries with local `Xenova/bge-small-en-v1.5`
  vectors (`source: local-title`, `embl-` ref prefix). ~130MB model download
  on first use.
- **Pooling is MEAN, not CLS** — determined empirically 2026-06-11 against
  prod vectors: Workers AI's `@cf/baai/bge-small-en-v1.5` mean-pools (mean
  pooling gives cosines 0.999999–1.000000 vs stored prod embeddings; CLS
  gave 0.93–0.97). Do not "fix" `src/seeder/local-embedder.ts` back to CLS
  without re-running the parity gate.
- **Parity gate**: whenever the corpus contains prod (`emb-`) vectors, up to
  5 `source: thread-title` vectors are re-embedded locally; ALL cosines must
  be ≥ 0.99 or **nothing is written** (no mixing of divergent local vectors
  with prod vectors). `--parity-only` runs just the gate (exit 0 pass /
  2 fail).
- **Re-titling a synthetic entity**: `embl-` refs are derived from the
  entity **id**, not the title — changing a title does NOT change the ref,
  and gen-embeddings only fills null refs. You must (a) set the entity's
  `embedding_ref: null` AND (b) delete the stale entry from
  embeddings.yaml (leaving it would either serve the old title's vector or
  collide as a duplicate ref), then re-run gen-embeddings.

## 8. Privacy / leak policy

- **Single write choke point**: all prod-extracted data becomes YAML only
  through `buildCorpusFiles` / the append pipeline (`src/seeder/emit.ts`,
  `src/seeder/append.ts`), where anonymization and the enforced `leakCheck`
  run. A raw email/name/org-domain appearing **outside** title scope is a
  **violation — nothing is written**. Hits on `title:` / `gold_rationale:` /
  `notes:` lines are **warnings**: an audit list for human review (titles
  are preserved verbatim by policy).
- **Titles verbatim, topics rewritten**: thread/priority titles stay as-is;
  email-shaped substrings inside topics (e.g. `channel:kris@plot.day`) are
  rewritten through the email anonymizer, preserving topic equality and
  `channel:`/`priority:` structure.
- **Anonymizer** (`src/seeder/anonymize.ts`): fully deterministic
  (sha256-seeded; same input ⇒ same output across runs/scripts — NOT
  idempotent, so never re-anonymize already-fake values). Freemail domains
  map into a fixed pool of 6 REAL freemail domains (present in the DB's
  freemail seed, so freemail-ness survives `connection_org_key`); org
  domains map to fake-but-realistic org domains with **equality preserved**
  (org-key grouping intact). Names come from curated pools; group names get
  contact-name tokens replaced; team/twist-instance names are synthesized,
  never extracted. **The raw→fake mapping is never written to disk.**
- **Leak-check CLI** (spot check, no prod access needed):

  ```bash
  pnpm exec tsx src/seeder/leak-check.ts --corpus <name>
  ```

  Heuristic only: flags email-shaped strings whose domain is neither
  freemail-pool nor example-shaped, grouped by domain for HUMAN review, and
  always exits 0. It cannot distinguish the anonymizer's realistic fake org
  domains from real leaks, nor detect leaked freemail addresses or bare
  names — only the seeder-side `leakCheck` (which holds the raw PII list)
  can. Expect a long candidate list on healthy corpora; it's an audit aid,
  not a gate.

## 9. Corpora inventory

| Corpus | Kind | Trainings (full) | Cases | Gold coverage | Role |
| --- | --- | --- | --- | --- | --- |
| `kris` | prod-extract | 144 threads (+ `first-day` ×2, `empty`) | 92 (80 + 12 `holdout-move`) | 92/92 (66 human / 26 llm-proposed) | **Primary tuning surface.** Its 12 holdout-move cases are part of the FINAL holdout — never `--include-holdout` here during tuning. |
| `prod-u2` | prod-extract | 103 threads | 57 (47 + 10 `holdout-move`) | 10/57 (all holdout-move, human) | **FINAL HOLDOUT — do not run during tuning.** Evaluated exactly once (with `--include-holdout`; its only gold cases are the holdout ones). |
| `prod-u3` | prod-extract | 24 threads | 61 (55 + 6 `holdout-move`) | 6/61 (all holdout-move, human) | Tuning, **including** its 6 holdout-move cases (designated tuning data — they're its only gold labels; `--include-holdout` is acceptable here). Sparse-training regime. |
| `synthetic-tiny` | handcrafted | 2 threads | 5 | 5/5 by construction | Loader/sandbox fixture; smoke runs. |
| `synthetic-newsletter-flood` | handcrafted | 20 threads | 15 | 15/15 by construction | Facet-gate material: `facet_filters` excludes, trusted-sender bypass, gate-drops-winner. |
| `synthetic-two-hats` | handcrafted | 22 threads | 15 | 15/15 by construction | Multi-account work/personal routing: org-key exact/org/none, account hierarchy, origin bonus. |
| `synthetic-groups` | handcrafted | 19 threads | 15 | 15/15 by construction | Group-overlap vs topic noise; multiple plausible targets (tiebreaker + rank-of-gold). |

Synthetic results never pool with real-data results (§4). Each prod corpus's
README records its exact re-generation command.

## 10. Troubleshooting

- **IDE/LSP diagnostics look wrong** — they are often stale in this
  package. Trust `pnpm lint` (tsc) and `pnpm test`, not editor squiggles.
- **`ERR_PARSE_ARGS_UNEXPECTED_POSITIONAL` from the CLI** — you invoked it
  via `pnpm --filter @plotday/eval eval -- …`; pnpm forwards a literal
  `--`. Use `cd libs/eval && pnpm exec tsx src/cli.ts …`.
- **`pnpm test` is green but suspiciously fast / few tests** — vitest's DB
  suites are `describe.runIf(!!process.env.DATABASE_URL)` and skip
  silently. Export `DATABASE_URL` (expect 342 tests).
- **`contact_email_unique` violation during seeding** — two distinct raw
  emails anonymized to the same fake address. The anonymizer dedupes
  deterministically since 2026-06-11 (`71e0df202`); if an older corpus
  trips it, re-extract with the current seeder.
- **`thread_title_required` violation during seeding** — draft prod threads
  have no title; extraction excludes drafts since `ac87b47bb`. Re-extract
  if a corpus predates the fix.
- **Wrong thread re-hydrated / ambiguous-prefix report on refresh** — case
  ids embed only 8 hex chars of a uuidv7 (timestamp-prefixed ⇒ prefix
  collisions are real). `source_thread_id` is authoritative; the refresher
  disambiguates prefix multi-matches by exact title and otherwise keeps the
  case verbatim and reports it. If a case lacks `source_thread_id`, add it.
- **A case scores suspiciously perfectly** — check the `Self-exclusions`
  count (console format): if the case's thread is in the training set the
  guard should have archived it. If the case has neither `source_thread_id`
  nor a prefix-parseable id, the guard cannot match it — fix the case id or
  add `source_thread_id`.
