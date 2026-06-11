# Eval framework: corpus v2, seeders, backtest, statistics, first tuning pass

**Date:** 2026-06-11
**Status:** Approved design (autonomous run; user gates replaced by adversarial self-review)
**Related specs:**
- `2026-06-10-classifier-signal-port-decision-log-design.md` (predecessor: signals ported to TS, `classification_decision` log)
- `2026-05-18-hybrid-thread-classifier-design.md` (TS hybrid cascade)
- `2026-06-08-thread-facet-classification-design.md` (facet gate)
- `2026-06-09-connection-origin-classification-design.md` (origin signal)

## Context

`libs/eval` runs the production TS hybrid-LLM cascade against YAML corpora in
a transactional pg sandbox. The predecessor workstream ported the facet gate
and connection-origin signal into the TS scoring stage and added the
`classification_decision` append-only log — but the eval corpus (schema v1)
cannot express any of the new signals: no facets, no `facet_filters`, no
priority descriptions, no negatives, no connections (so `connection_org_key`
is unresolvable and channels use a placeholder FK hack), no subscription
tier, no timestamps. Both new signals are inert in eval; `originBonus`
defaults (0.18/0.09) are untuned guesses.

This workstream builds the evaluation infrastructure that makes classifier
optimization evidence-driven, then runs the first tuning pass with it.

### Current state inventory

- **Corpora**: `kris` (80 cases, ~60 gold-labeled, 34 training threads,
  schema v1), `synthetic-tiny` (handcrafted, v1).
- **Harness**: `src/corpus/schema.ts` (zod v1), `src/corpus/load.ts`
  (slug→UUID resolution), `src/sandbox/pg-sandbox.ts` (one transaction,
  savepoint per case; `session_replication_role=replica` during world load),
  `src/runner/run.ts` (training-set × classifier matrix), `src/scoring/report.ts`
  (accuracy, stage breakdown, flips, misses), `src/cli.ts`.
- **Seeders**: `from-prod.ts` (full re-extract, stratified sampling),
  `add-prod-cases.ts` / `add-prod-trainings.ts` (append curated threads),
  `backfill-*.ts` (one-off field backfills), `anonymize.ts`
  (hash-opaque emails/names), `slugs.ts`.
- **Known fidelity gap**: v1 puts the note-author *contact* into
  `thread.created_by`. Production puts the *twist_instance* (connection)
  there for connector-created threads and the contact into
  `thread.author_id`. The author signal and twist-author shortcut therefore
  behave differently in eval than in prod.
- **Hygiene drift**: `corpora/kris/baseline-report.md` says 30 cases /
  sql:current only; README describes a `cases/NNN-*.yaml` layout that no
  longer exists.

## Goals

1. The corpus format can express **every signal** the production classifier
   consumes (facets, facet filters, descriptions, negatives, connections +
   org keys, subscription tier, timestamps), and the sandbox inserts all of
   it so the signals are genuinely exercisable.
2. Corpora can be (re-)extracted from prod for multiple users with
   **shape-preserving anonymization** that survives the LLM stages and
   `connection_org_key` semantics, plus an enforced leak check.
3. Ground truth grows three new ways: **move-holdout** extraction,
   **decision-log mining**, and **LLM-proposed gold labels** (clearly
   marked, never overwriting human labels).
4. The runner can **replay time** (cold-start → warm trajectory) and the
   report can tell **signal from noise** (Wilson CIs, McNemar, rank-of-gold,
   per-tag slices, token/cost accounting).
5. A **first tuning pass** produces a registered `ts:hybrid-llm:tuned-2026-06`
   variant and an evidence report with a PROPOSED (not applied) diff to
   production defaults.

## Non-goals

- CI workflows / GitHub Actions.
- Production DB schema changes (everything here is eval-side).
- Changing production `DEFAULTS` / `DEFAULTS_LLM` (J proposes only).
- `public/` submodule changes.
- Re-routing the SQL trigger paths; retention crons; PostHog enrichment.

---

## A. Corpus schema v2

`schema_version: 2`. The loader continues to accept v1 documents and
normalizes them to v2 in memory (missing fields ⇒ inert defaults, v1
`author` semantics preserved — see A6). `synthetic-tiny` is upgraded to v2
syntax in place as the worked example.

### A1. World additions (`world.yaml`)

```yaml
schema_version: 2
user:
  id: <uuid>
  email: eval-user@example.test
  primary_contact_id: null
  subscription: { plan: pro, status: active }   # null/absent ⇒ no row (free)
teams:                                          # optional; for org_key 'team:' branch
  - { slug: acme-team, id: 7, name: Acme }
connections:                                    # twist_instance + connection rows
  - slug: gmail-work
    id: <uuid>                                  # twist_instance id
    provider: google
    account_contact: kris-work                  # contact ref; actor for org_key
    team: null                                  # optional team ref
priorities:
  - slug: inbox-zero
    id: <uuid>
    path: root.abc
    title: Inbox Zero
    key: null
    description: Email triage and follow-ups    # null default
    facet_filters:                              # null default; jsonb passthrough
      automation: { exclude: [automated] }
      trustedSendersOnly: true
contacts:
  - { slug: kris-work, id: <uuid>, email: kris@lumenforge.com,
      name: Kris Braun, linked_to_user: true }
channels:
  - id: 164
    connection: gmail-work                      # NEW: real FK parent (required in v2)
    default_priority_id: null
embeddings:                                     # plus optional sibling embeddings.yaml
  - ref: emb-abc123
    source: thread-title                        # NEW: thread-title | note-content | local-title
    vector: [...]
```

- **Connections** materialize as: one synthetic `twist` row per distinct
  provider (deterministic bigint id via `OVERRIDING SYSTEM VALUE`;
  required NOT NULLs synthesized: `twist_package_id` deterministic uuid,
  `name`/`handle`/`version` from the provider, `environment='personal'`,
  `user_id` = world user, `publisher_id` NULL — satisfying
  `twist_owner_check`), a `twist_instance` (owner = world user, `name`
  synthesized from provider + slug, `team_id` from the optional team
  ref), and a `twist_instance_connection` (provider, `actor_id` =
  account_contact, `user_id` = world user). This makes
  `public.connection_org_key(<connection id>)` resolve exactly as in prod:
  non-freemail actor-email domain → `domain:<d>`, else team → `team:<id>`,
  else NULL. The dev/worktree DB already seeds the freemail `domain` rows
  (`libs/db/schema/99-data/10-domains.sql`).
  `session_replication_role=replica` disables triggers/FKs but **not**
  NOT NULL or CHECK constraints — every synthesized column above is load-
  bearing.
- **Channels** in v2 must reference a declared connection; the v1
  placeholder hack (`twist_instance_id = user.id` under disabled triggers)
  is removed for v2 corpora (still applied when loading v1).
- **Teams** exist only to exercise the `team:` org-key branch; rows are
  inserted with `OVERRIDING SYSTEM VALUE`.
- **Numeric identity ids** (teams, synthetic twists; channel ids already
  come from prod) declared by corpora are offset into a high range
  (≥ 10⁹) at insert time, and inserts **fail loudly** on conflict instead
  of `ON CONFLICT DO NOTHING` — a silent collision with live dev rows
  (e.g. an existing channel's real `default_priority_id`) corrupts
  results invisibly. The v1 channel-insert conflict behavior is kept only
  for v1 corpora.
- **Embeddings file split**: the loader merges `world.embeddings` with an
  optional sibling `embeddings.yaml` (`{ embeddings: [...] }`). Seeders
  write embeddings to the sibling file so `world.yaml` stays reviewable.

### A2. Thread-shaped additions (training sets, `trainings/*.yaml`)

```yaml
threads:
  - id: <uuid>
    title: ...
    topic: null
    contacts: [kris-work, vendor-anna]
    groups: []
    embedding_ref: emb-abc123
    filed_to_priority: inbox-zero
    author: vendor-anna          # contact ref → thread.author_id
    connection: gmail-work       # NEW: → thread.created_by + thread.twist_id
    facets: { format: message, automation: automated, reach: broadcast }
    created_at: 2026-04-02T10:00:00Z   # thread arrival
    moved_at: 2026-04-03T09:30:00Z     # when the user filed it (backtest ordering)
negative_threads:                # threads that exist only as negative evidence
  - { id: <uuid>, title: ..., contacts: [...], embedding_ref: ..., author: ...,
      connection: ..., facets: ..., created_at: ... }
negatives:                       # mirror of thread_priority_negative
  - { thread: <uuid-or-id-of-training-or-negative-thread>,
      priority: inbox-zero, source: moved_out,    # source ∈ moved_out|deselected
      created_at: 2026-04-05T08:00:00Z }          # real row timestamp (backtest clock)
```

- All new fields nullable/optional with inert defaults.
- The sandbox inserts `author_id`, `created_by` (= connection id when set,
  else world user id), `twist_id` (the synthetic twist's bigint id),
  `facets`, and explicit `created_at` (triggers are disabled during
  training load, so the value sticks).
- `negatives` insert `thread_priority_negative` rows; `negative_threads`
  insert thread rows without a `thread_priority` filing.
- Negatives are per-training-set so the training-set matrix stays coherent
  (empty set ⇒ no negatives).

### A3. Case additions (`cases.yaml`)

```yaml
cases:
  - id: 001-019e088a
    source_thread_id: <uuid>             # NEW: full prod thread id (refresh + self-exclusion)
    tags: [channel, facet-gate]          # NEW: free-form slice labels
    as_of: 2026-05-01T12:00:00Z          # NEW: runner-side backtest clock (the staged
                                         #   thread row's created_at is clobbered by the
                                         #   set_created_at trigger — never read from DB)
    candidate:
      title: ...
      topic: channel:164
      contacts: [...]
      groups: []
      embedding_ref: ...
      author: vendor-anna                # contact ref → authorContactId + author_id
      connection: gmail-work             # NEW: → connectionId / created_by / twist_id
      facets: { format: message }        # NEW
    labels:
      gold: inbox-zero
      gold_rationale: ...
      gold_source: human                 # NEW: human | llm-proposed | null
      expected: plot
      expected_stage: null               # widened from enum to free string
      expected_recorded_at: ...
```

- `expected_stage` becomes `z.string().nullable()` — the old enum predates
  the TS cascade's stage names (`llm_tiebreaker`, `llm_coldstart`, …) and
  would reject them.
- `gold_source` defaults: `human` when `gold` is set and the field is
  absent (all existing labels are Kris's), else `null`.
- `source_thread_id` is written by all seeders going forward; pre-existing
  cases fall back to the 8-hex-char prefix embedded in the case id.

### A3a. Case/training self-exclusion guard (anti-leakage)

A case whose source thread also exists in the training set (it was later
`user_moved`, or it was mined from the decision log) would otherwise score
`sem≈1.0` against its own training copy — a leaked answer that corrupts
every tuning measurement. Two defenses, both mandatory:

- **Runner guard (always on)**: at run start the runner matches each case
  (`source_thread_id`, falling back to the case-id prefix) against the
  loaded training set; inside the case's savepoint, before `classify()`,
  the matching training thread is archived (`UPDATE thread SET archived_at
  = now()` — the neighbor query filters archived) so it is invisible for
  that case only and remains training signal for all other cases. The
  report prints the number of self-exclusions per run.
- **Seeder discipline**: `--holdout-recent-moves` threads are additionally
  excluded from the emitted training set entirely (a clean holdout must
  not appear as contemporaneous training for sibling holdout cases).

### A4. Runner & candidate wiring

`runOneCase` passes `facets`, `authorContactId` (the case author contact),
and `connectionId` (the case connection) to `classifier.classify()`, and
`stageCandidate` writes `author_id`, `created_by`/`twist_id` accordingly.
The author-fallback rule matches prod: `created_by` = connection id when
present, else the world user id (self-authored). v1 corpora keep their old
`created_by` = author-contact behavior via loader normalization (A6).

### A5. Sandbox additions (`pg-sandbox.ts`)

`loadWorld` additionally inserts: `user_subscription` (when declared;
`billing_cycle_start/end` fixed constants), `team`, `twist` (per provider),
`twist_instance`, `twist_instance_connection`, `priority.description`,
`priority.facet_filters`, `contact.name`. `loadTrainingSet` inserts the new
thread columns, `negative_threads`, and `negatives`. Channel rows now
reference their declared connection's `twist_instance` id (v2) or fall back
to the v1 placeholder during compat loading.

### A6. v1 compatibility & regression gate

- Loader: `schema_version: 1` documents are upgraded into an internal
  model that is a **superset** of v2 — v1's `author` semantics (contact id
  written into `thread.created_by`) has no v2 spelling, so the internal
  thread shape carries a `created_by_override` that v1 normalization sets
  and v2 documents never use.
- Under v1 compat the sandbox behaves **exactly** as today: no
  `contact.name` insertion (the tiebreaker prompt renders
  `COALESCE(name, email, id)`, so inserting names changes LLM prompts and
  cache keys), placeholder channel parent, conflict-tolerant channel
  insert.
- **Regression gate**, two layers:
  1. A durable vitest fixture: a frozen v1 corpus snapshot (copied into
     `tests/fixtures/`) with a recorded prediction snapshot for
     `ts:hybrid:default` — byte-identical predictions required. (The live
     `corpora/kris` stops being v1 after C, so the gate must not point at
     it.)
  2. An implementation-time gate on the LLM path: run `kris` (v1, as
     committed) with `ts:hybrid-llm:default` before the refactor to
     populate the LLM cache, re-run after the refactor, and require **zero
     cache misses** plus identical predictions — a cache miss proves a
     prompt changed.
- After the gate passes, `kris` is re-extracted through the v2 pipeline
  (C); v2 scores may legitimately differ (better fidelity) and the report
  records the delta.

## B. Shape-preserving anonymization (`src/seeder/anonymize.ts`)

Replaces `Person <hash>` / `c-<hash>@example.test` with realistic,
deterministic fakes. All derivations are `sha256(NAMESPACE + input)`-seeded
— same input ⇒ same output across re-runs and across scripts.

- **Names**: curated first/last pools (~200 × ~200); `anonymizeName(name)`
  picks deterministically. Multi-token names → "First Last"; single-token →
  one fake token.
- **Domains** (`anonymizeDomain`):
  - *Freemail* input domains (detected against the freemail list parsed
    from `libs/db/schema/99-data/10-domains.sql`, with a hard-coded core
    fallback) map deterministically into a fixed pool of real freemail
    domains (`gmail.com`, `yahoo.com`, `outlook.com`, `hotmail.com`,
    `icloud.com`, `aol.com`) — all present in the DB's freemail seed, so
    freemail-ness survives in `connection_org_key` /
    `author_matches_org_domain`.
  - *Org* domains map to stable fake org domains built from word pools
    (e.g. `lumenforge.com`) — absent from `public.domain`, so they count
    as org domains, and domain **equality is preserved** (same source
    domain ⇒ same fake domain), keeping org-key grouping intact.
- **Emails** (`anonymizeEmail(email, name?)`): local part derived from the
  anonymized name when available (`jordan.mercer@…`), else from the local
  part's hash; domain via `anonymizeDomain`. Deterministic in its inputs.
- **Topics** (`anonymizeTopic(topic)`): email-shaped substrings inside
  topic strings are rewritten through `anonymizeEmail` (the kris corpus
  contains e.g. `channel:kris@plot.day`; Gmail channels are keyed by
  address). Determinism preserves topic equality and the `channel:` /
  `priority:` prefix structure, so `topicFuzzy` and the topic
  short-circuit behave identically. Everything else in the topic stays
  verbatim.
- **Group names**: tokens matching any collected contact-name token
  (case-insensitive) are replaced with the corresponding anonymized name
  tokens (messaging groups are routinely named after participants);
  remaining group names go to the warn-and-audit bucket (see leak check).
- **Team names** and **twist_instance names**: never extracted — they
  routinely embed account emails/org names (`account_label` like
  "Gmail (kris@…)"). Synthesized from provider + slug instead;
  `connection_org_key` only uses `team:<id>`, so nothing is lost.
- The mapping is **never written to disk**; it is recomputed from raw
  values whenever needed.
- Priority/thread titles, channel ids, and UUIDs stay verbatim (existing
  policy, documented in `from-prod.ts`).
- All seeder-written templates (world `description`, trainings
  description, README) use the **anonymized** email for every corpus,
  kris included — otherwise the leak check fails on its own output.

### Leak check

`from-prod` (and every appending seeder) collects the raw PII it saw —
emails, contact names, and non-freemail domains — and scans every
serialized YAML document before writing:

- A raw value appearing **outside** thread/priority title fields ⇒ hard
  failure, nothing written.
- A raw value appearing **inside** a preserved-verbatim title ⇒ warning
  listing the affected case/thread ids for manual audit (titles are exempt
  by policy but Kris reviews the list in the final report).

A standalone `pnpm tsx src/seeder/leak-check.ts --corpus <name>` performs a
heuristic scan (email-shaped strings whose domain is neither the freemail
pool, fake-org shaped, nor `example.*`) for spot checks without prod access.

## C. Seeder upgrades

### C1. Shared extraction module

`from-prod.ts`, `add-prod-cases.ts`, `add-prod-trainings.ts`, and the new
miners currently duplicate row-shaping; a shared `src/seeder/extract.ts`
gains the canonical helpers: thread row hydration (title/topic/contacts/
groups/embedding/author_id/connection/facets/created_at), world-entity
collection (contacts, groups, connections incl. provider + actor contact,
channels, teams, subscription, priorities with `facet_filters` +
`description`), negative extraction (`thread_priority_negative`), and v2
YAML emission (world / trainings / cases / embeddings.yaml) with the
anonymization + leak-check pipeline applied at the single write choke
point. The `add-prod-*` scripts are migrated onto it (same CLI contract).

### C2. `from-prod` v2

- Extracts everything A models. Connection of a thread =
  `thread.created_by` when `thread.twist_id IS NOT NULL`; its provider and
  actor contact come from `twist_instance_connection` (owner row).
  Subscription from `user_subscription`. Negatives from
  `thread_priority_negative` (threads hydrated as `negative_threads` when
  not already in the training set).
- Timestamps: training `moved_at` = `thread_priority.updated_at` (best
  available approximation until decision-log history accrues — documented
  caveat), `created_at` = `thread.created_at`; case `as_of` =
  `thread.created_at`. Negatives carry their real
  `thread_priority_negative.created_at`.
- Foreign-owned connections: prod threads are frequently created by a
  twist_instance owned by **another** user (shared Slack/group threads).
  Extraction remaps the connection's owner to the world user and
  synthesizes its `twist_instance_connection` from the real actor contact
  (third-party PII — flows through anonymization like any contact);
  `connection_org_key` still resolves via the actor's email domain.
- **Refresh-preserving-labels**: before writing cases, load the existing
  `cases.yaml` (if present); every existing case is re-hydrated from prod
  by `source_thread_id`, falling back to the case-id's embedded 8-hex-char
  prefix (ambiguous or missing prefixes are reported and the case kept
  verbatim), upgrading candidate fields to v2 while preserving `gold`,
  `gold_rationale`, `gold_source`, `expected*`, `notes`, `tags`
  byte-for-byte. New sampled cases are appended with continuing numbering.
- **Corpus-wide slug migration on refresh**: the new anonymizer changes
  every contact slug (slugs derive from anonymized emails). The refresh
  builds an old-slug → UUID map from the existing `world.yaml` and
  rewrites slug references in **all** corpus files — including extra
  training files under `trainings/` (e.g. kris's `first-day.yaml`), which
  are otherwise left untouched — so the corpus still loads afterwards.
- **`--holdout-recent-moves N`**: the N most recent `user_moved` threads
  (by `thread_priority.updated_at`) are excluded from `trainings/full.yaml`
  and emitted as cases with `gold` = the move target, `gold_source: human`,
  tag `holdout-move`. These become the tuning holdout (J).
- **Multi-user**: `--user-email` already parameterizes; a helper query
  surfaces the 2–3 most active non-kris users by `thread_priority` row
  count. Their corpora are named `prod-u2`, `prod-u3`, … and contain no
  raw identity anywhere (README/description reference the anonymized email
  only). Authorized explicitly; titles verbatim per policy.

### C3. Decision-log mining (`from-decision-log.ts`)

Appends labeled cases to an existing corpus from `classification_decision`
history: for the corpus user, an auto row (`classifier != 'user'`)
followed by a `user_move` row with a **different** `priority_id` is a
labeled misclassification — gold = the move target (`gold_source: human`,
tag `decision-log`), `as_of` = the auto row's `created_at`, expected = the
auto row's choice (asymmetry note: TS no-match rows log stage `none` with
NULL priority; SQL trigger rows log `sql:applied` with root resolved —
both belong to the "low-confidence" bucket and are recorded in `notes`).
Threads are hydrated + anonymized via C1 against the same `--db-url`
(default: prod proxy; works against any DB). An empty or missing table
(prod until Kris deploys) prints an informative message and exits 0.

## D. Embedding backfill (`src/seeder/gen-embeddings.ts`)

- Local inference via `@huggingface/transformers` (eval devDependency),
  model `Xenova/bge-small-en-v1.5` (same weights as prod's
  `@cf/baai/bge-small-en-v1.5`), CLS pooling + L2 normalize, embedding the
  **title** (prod embeds `title || preview`; the corpus has titles only).
- **Provenance is recorded** (A1): embeddings carry
  `source: thread-title | note-content | local-title`. The prod seeders
  set it (`thread.embedding` → `thread-title`; the note-embedding fallback
  → `note-content`); the backfill writes `local-title` with an `embl-` ref
  prefix.
- **Parity gate** (runs before any backfill is written): pick 5
  `source: thread-title` vectors from the v2-refreshed kris corpus, embed
  the same title locally, require cosine ≥ 0.99 for all 5. (Provenance
  makes this selectable; v1 refs cannot distinguish title vectors from
  note-content fallbacks.) On failure — plausible if Workers AI pooling
  differs from local CLS pooling — no mixing: `embl-` vectors are
  reported, excluded from corpora containing prod vectors (the kris
  backfill is then skipped and reported as blocked), and used only where a
  corpus is uniformly local (synthetics).
- On success, `embl-` refs mix freely with prod `emb-` vectors (prefix
  keeps provenance visible).
- Fills: the 9 kris cases + 8 `full.yaml` training threads + 2
  `first-day.yaml` training threads with `embedding_ref: null`, and all
  synthetic corpora (G).
- Privacy: `note-content` vectors embed private message bodies
  (embedding-inversion recovers approximations). They are **excluded from
  non-kris corpora**; the kris corpus keeps them (own data, existing
  committed practice).

## E. Time-replay backtest

- `runEval` gains `mode: "matrix" | "backtest"` (CLI `--backtest`).
- Backtest requires `as_of` on every selected case and `moved_at` on
  training threads (cases without `as_of` are skipped with a warning;
  count reported). One training set (default `full`) is used.
- Cases sort by `as_of`; the runner inserts training threads with
  `moved_at < as_of` progressively in the outer transaction (monotonic —
  no rollback between cases), then stages each case in its savepoint as
  today. Negatives follow the same clock via their own `created_at`
  (the real `thread_priority_negative.created_at`, extracted in C).
- Each RunResult records `trainingSizeAtCase`; the report adds a
  cold-start trajectory table (gold accuracy bucketed by training size:
  0, 1–5, 6–15, 16–30, 31+).
- Seeder support: `--timeline-cases N` samples N auto-filed threads spread
  evenly across the user's `created_at` timeline (instead of stratified
  topic-shape sampling) for backtest-oriented corpora.

## F. CLI ergonomics + honest statistics

### F1. Variants without registry edits

- `--params <file.json>`: deep-merge onto a base variant's `HybridParams`
  (`--base ts:hybrid-llm:default`, default as shown); registers an ad-hoc
  variant `ts:hybrid-llm:params@<shortHash>` for this run. Weight
  validation (`assertValidWeights`) still applies; sweeping a single
  `weights.*` dimension **renormalizes the remaining weights
  proportionally** so the sum-to-1 invariant holds (rule documented in the
  CLI help and runbook).
- `--sweep "<spec>"`: grid sweep, e.g.
  `originBonus.exact=0:0.3:0.05;originBonus.org=0|0.09` (`start:end:step`
  ranges and `|`-separated explicit lists; `;`-separated dimensions; cross
  product). Each point becomes an ad-hoc variant; output is a leaderboard
  sorted by gold accuracy with CIs and a McNemar flag vs the base.
- **Cache-honesty**: only params that gate *whether* the LLM fires
  (`highConfidenceFloor`, `marginFloor`, `supportingFloor`,
  `scoreThreshold`, budgets) reuse the LLM cache well. Params that reorder
  scoring (`weights`, `originBonus`, `negativePenaltyWeight`,
  `accountHierarchyBonusWeight`, aggregation `k`) change the tiebreaker
  prompt's candidate set/exemplars ⇒ live calls per point. Broad grids
  over ranking params therefore run the **deterministic** `ts:hybrid`
  variant (cheap proxy, clearly labeled in output); only the shortlisted
  configs get full `ts:hybrid-llm` runs. The runbook documents this and
  the expected live-call budget per sweep shape.
- `--exclude-tags <list>` / `--include-holdout`: holdout-tagged cases
  (`holdout-move`) are **excluded by default** from every run so routine
  runs and sweeps cannot touch the holdout; `--include-holdout` is the
  single, explicit way to evaluate it (J).
- **Budget gate neutralized in eval**: the registry injects an unlimited
  `consumeBudget` (the in-process per-user budget counters would silently
  degrade long sweeps to deterministic scoring after ~5000 calls — free
  tier — corrupting later grid points). `RunResult` and the report surface
  `budgetExhausted` regardless, so any budget interaction is visible.

### F2. Baselines

- `--save-baseline <file>`: writes per-case predictions
  (`{meta, results: {caseId: {predicted, stage}}}`).
- `--baseline <file>`: comparison classifies each case as
  `fixed` (was ≠ gold, now = gold), `broke` (was = gold, now ≠ gold),
  `changed-neutral`, or `same`; prints the lists and McNemar's exact test
  on the fixed/broke discordant pair.

### F3. Diagnostics & statistics (`src/scoring/stats.ts`, report)

- **Rank-of-gold**: for each gold miss, the gold priority's rank and score
  margin inside the scoring explain (`null` when the stage never ranked,
  e.g. structural). Aggregates: top-3 hit rate, MRR over ranked cases.
- **Per-tag slices**: gold accuracy per case tag.
- **Wilson 95% CI** on every gold-accuracy figure (report renders
  `acc% [lo–hi]`).
- **McNemar exact test** for paired variant comparisons; the report
  prints "within noise" when p ≥ 0.05.
- **Token/cost accounting**: `LLMOutput` gains optional
  `usage {inputTokens, outputTokens}`; the eval Gemini client populates it
  from the `ai` SDK result, the file cache stores + replays it, and the
  cascade aggregates into `ClassificationResult.llmUsage`. The report
  separates **live** spend (cache misses — what the run actually cost)
  from **replayed** usage (cache hits); cache entries written before the
  usage field existed count as *unknown*, not zero. Cost estimated from a
  constants table in `src/scoring/cost.ts` (per-model $/1M in+out, clearly
  marked estimates). Type changes to `libs/classifier` are
  additive/optional — workers code is untouched.

## G. Synthetic corpora (handcrafted, no API needed)

Three personas under `corpora/`, labels by construction, embeddings via D,
worlds documented inline:

1. **`synthetic-newsletter-flood`** — facet-gate material: newsletters,
   receipts, promos vs trusted senders; priorities with `facet_filters`
   (automation excludes, `trustedSendersOnly`), trusted-sender bypass
   cases, gate-drops-winner cases.
2. **`synthetic-two-hats`** — multi-account work/personal routing: two
   connections (org domain + freemail), org-key exact/org/none neighbors,
   account-hierarchy affinity, origin-bonus discrimination cases.
3. **`synthetic-groups`** — group-heavy world with ambiguous topics:
   group-overlap signal vs topic noise, multiple plausible targets
   (exercises tie-breaker + rank-of-gold reporting).

Synthetic results stay separated from real-data results in every report
(corpus provenance comes from `world.source.kind`).

## H. Gold-label completion (`src/seeder/propose-gold.ts`)

For cases with `gold: null`: prompt Gemini (same eval LLM client + cache,
but its **own promptId** — `propose-gold-v1` — so cache entries cannot
collide with classifier prompts) with the world's priority tree (titles,
paths, descriptions), a sample of same-corpus training filings, and the
candidate; write the proposal as `gold` + `gold_rationale` +
`gold_source: llm-proposed`. Human labels are never overwritten (only
`gold: null` cases are touched; `--force` does not exist). The final
report lists every proposal for Kris's audit, and all accuracy reporting
slices by `gold_source` so the circularity risk (same model family judges
and classifies) stays visible. Runs on the kris corpus (~20 unlabeled
cases).

## I. Runbook (`libs/eval/AGENTS.md`) + hygiene

The operating manual for the next optimizing agent: how to run/seed/sweep
(exact commands, explicit `DATABASE_URL`, `cd libs/eval && pnpm exec tsx
src/cli.ts` invocation — never `pnpm --filter … eval --`), which metrics
matter (gold accuracy + CI, per-slice, rank-of-gold, cost), guardrails
(holdout discipline; noise thresholds; LLM cache hygiene — when to wipe
`.cache/llm`; re-seeding rituals incl. refresh-preserving-labels; leak
check; decision-log mining once prod deploys), and corpus authoring notes.
Hygiene fixes: regenerate `corpora/kris/baseline-report.md` from the new
CLI (or replace with a pointer to the reports dir), fix the README corpus
layout description, document the v2 layout.

## J. First tuning pass (after A–I are green)

Protocol (written into the runbook as the worked example):

1. **Holdout discipline**: the kris `--holdout-recent-moves` cases + one
   other-user corpus are designated the **final holdout** — excluded by
   default from every run (`--include-holdout` is the only path in),
   evaluated exactly once at the end. With realistic holdout sizes
   (~10–25 cases) the holdout is a **directional sanity check**, not a
   significance test — stated as such in the report.
2. **Tuning surface**: kris main cases (gold), synthetics (G), the
   remaining other-user corpora, and the backtest trajectory.
3. Sweeps: broad grids over ranking params (`originBonus.{exact,org}`,
   `weights` with renormalization, aggregation `k`,
   `negativePenaltyWeight`, `accountHierarchyBonusWeight`) run the
   deterministic variant; floor/threshold sweeps and shortlisted configs
   run the full LLM cascade (F1's cache-honesty rules).
4. **Honest statistics**: with ~60–80 gold cases, McNemar at α=0.05 needs
   roughly a 6–0/8–1 discordant split — small nudges are individually
   unfalsifiable, and a large grid produces ~5% false "significant" flags
   by multiplicity. Therefore: (a) the sweep is exploratory; the report
   states the number of comparisons run; (b) **at most 3 candidate
   configs are pre-registered** from the tuning surface before any
   holdout run; (c) the final paired McNemar test pools all real-data
   corpora (kris + other users) to maximize n; (d) **"no change
   proposed" is a first-class outcome** — if nothing clears the noise
   band, the evidence report says so and production defaults stand.
5. Deliverables: registered `ts:hybrid-llm:tuned-2026-06` variant (eval
   registry only), evidence report (what moved, by how much, CIs, holdout
   result, comparisons count, live token cost), and a PROPOSED diff to
   `DEFAULTS`/`DEFAULTS_LLM` in the report — production defaults are not
   touched.

## Testing strategy

- **Schema/loader**: vitest — v2 parse, v1 compat normalization, slug
  resolution for new refs, embeddings.yaml merge, negative refs, dup
  detection. `synthetic-tiny` (upgraded) remains the loader fixture.
- **Sandbox**: vitest against `$DATABASE_URL` — connections resolve
  `connection_org_key` (freemail vs org vs team), facet_filters reach the
  gate, negatives reach the penalty, subscription reaches the budget tier,
  v1 placeholder channel path still works.
- **Regression gate**: frozen v1 fixture corpus under `tests/fixtures/`
  with recorded `ts:hybrid:default` predictions (durable vitest), plus the
  implementation-time zero-cache-miss gate on `ts:hybrid-llm:default`
  against the as-committed kris v1 corpus (A6).
- **Self-exclusion guard**: a case whose thread is in the training set is
  classified without it (vitest: same thread as case + training ⇒ not a
  sem≈1.0 self-match; report counts self-exclusions).
- **Anonymizer**: determinism, freemail pool membership, org-domain
  equality preservation, name realism shape, leak-check fail/warn paths.
- **Stats**: Wilson + McNemar against known fixtures.
- **Backtest**: synthetic timeline corpus — training set visible to case N
  is exactly the moves before its `as_of`; trajectory bucketing.
- **Seeders**: extraction helpers tested against the worktree DB by
  inserting fixture rows (prod access not needed in tests).
- **Embedding parity**: the gate itself is the test; plus a unit test that
  cosine(identical vectors) = 1 and the ref-prefix logic.

## Privacy review

- Anonymization upgraded (B) **before** any non-kris extraction (C order
  enforced in the plan).
- Leak check enforced at every YAML write; title-field and residual
  group-name hits surfaced for audit in the final report.
- Topics rewritten (emails inside topic strings); team and twist_instance
  names synthesized, never extracted; group names scrubbed of contact-name
  tokens.
- `note-content` embedding vectors (private message bodies) excluded from
  non-kris corpora.
- The anonymization mapping never persists; corpus names and READMEs for
  non-kris users carry no raw identity; all seeder templates use the
  anonymized email for every corpus.
- Prod access is read-only via the existing readonly proxy; no writes.

## Decisions at forks (recorded for the final report)

1. **created_by fidelity**: v2 models prod semantics (connection in
   `created_by`, contact in `author_id`); v1 compat keeps old behavior to
   protect the regression gate. Kris corpus re-extraction will shift some
   scores — accepted for fidelity, delta reported.
2. **Freemail pool = real freemail domains** (not fake ones) so the DB's
   freemail seed keeps classifying them; org domains get fake-but-realistic
   `.com` names from word pools.
3. **Titles verbatim** (existing policy) — leak check warns rather than
   fails on title hits.
4. **`moved_at` ≈ `thread_priority.updated_at`** until decision-log history
   exists in prod; documented as approximation.
5. **Case re-hydration by 8-char thread-id prefix** (case ids don't store
   full UUIDs); ambiguity handled by keeping the case verbatim + reporting.
6. **`expected_stage` widened to string** — the v1 enum predates TS stage
   names.
7. **Negatives live per-training-set**, not in the world, so the
   training-set matrix stays meaningful.
8. **Embeddings split to `embeddings.yaml`** (optional, loader-merged) for
   world.yaml reviewability.
9. **LLM-proposed gold uses the same Gemini model** as the classifier under
   test — a known circularity risk, mitigated by: marking
   `gold_source: llm-proposed`, separate reporting slices (per-gold_source
   accuracy), and Kris's audit list.
10. **Self-exclusion at the runner, not only the seeder** — archiving the
    case's own training copy inside the case savepoint keeps the thread as
    training signal for every other case (no data loss) while killing the
    leaked-answer path; only `--holdout-recent-moves` threads are dropped
    from training emission entirely.
11. **Broad ranking-param sweeps run the deterministic variant** — the
    tiebreaker prompt embeds the scoring ranking, so ranking params can't
    reuse the LLM cache; deterministic grids + LLM shortlists keep the
    token budget honest instead of pretending sweeps are free.
12. **Adversarial review (2026-06-11)** found 4 blocking issues (training
    leakage, topic emails, slug churn, embedding provenance) + 18 others;
    all folded into this revision. The critic's full findings list lives in
    the workstream report.
