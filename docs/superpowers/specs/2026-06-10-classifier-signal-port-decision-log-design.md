# Classifier signal port + classification decision log

**Date:** 2026-06-10
**Status:** Approved design
**Related specs:**
- `2026-05-18-hybrid-thread-classifier-design.md` (TS hybrid cascade)
- `2026-05-18-hybrid-classifier-production-wiring-design.md` (Worker dispatch, pending rows)
- `2026-06-08-thread-facet-classification-design.md` (facet gate — SQL only, until this spec)
- `2026-06-09-connection-origin-classification-design.md` (origin signal — SQL only, until this spec)

## Context

Production runs two classifiers concurrently:

1. **TS `ts:hybrid-llm` cascade** (`libs/classifier`, dispatched via
   `workers/api/src/state/classify-thread.ts` and the `workers/classify`
   queue consumer) — the primary path. Covers `/sync/capture`,
   `/sync/threads` auto_file, twist `thread-helpers`, all pending-row
   resolution, and post-move reclassification.
2. **SQL `classify_thread_for_user`** — survives at three inline trigger
   call sites where pending rows were deliberately rejected for latency
   reasons (see the comment block in `23-thread_group_peers.sql`):
   - `file_thread_priority_on_group_member_change` (user added to a group
     with existing threads), `libs/db/schema/95-triggers/23-thread_group_peers.sql`
   - `file_thread_priority_on_topic_member_change`,
     `libs/db/schema/95-triggers/30-topic_member_change.sql`
   - `apply_channel_default`, `libs/db/schema/60-functions/apply_channel_default.sql`

Two problems, both blocking classifier optimization work:

- The **facet gate** (2026-06-08) and **connection-origin signal**
  (2026-06-09) were added to the SQL function only — after the primary
  path had already moved to the TS cascade. Neither runs on the main
  flow today (`grep facet\|org_key libs/classifier workers/` → no hits).
- **No classification decision is recorded anywhere.** `thread_priority`
  is overwritten in place; the PostHog `classify.handled` event carries
  status/stage counts only. When a user moves a thread (the ground-truth
  correction signal), the decision it corrects is gone — so production
  corrections cannot be mined as labeled eval cases.

## Decisions made

- **Unification scope: port signals only.** Facet gate + origin move into
  the TS scoring stage. The three trigger paths keep calling the SQL
  scorer (accepted divergence: low traffic, latency-driven, mostly
  resolved by structural stages). Re-routing trigger paths through the
  queue is explicitly out of scope.
- **Decision log: DB table, including user-move rows.** A new append-only
  `classification_decision` table records every *applied* classification
  decision and every explicit user move, so labeled misclassifications
  become a self-join.

## Goals

- The signals from the two newest classifier investments run on the
  primary production path.
- Every applied filing decision and user correction is queryable from the
  prod readonly proxy, with enough payload (stage, top-k scores,
  classifier/params version) to mine labeled errors and measure live
  survival rate per stage/version.

## Non-goals (deferred)

- Routing the three SQL trigger paths through the queue/TS classifier.
- Eval-framework work: corpus schema v2 (facets/negatives/connections),
  seeder mining of the decision log, `--params`/sweep/baseline CLI.
  (Separate workstream; this spec only flips the eval CLI default.)
- Tuning `originBonus` constants — requires the eval corpus to model
  connections first. Ship with SQL-derived defaults.
- Retention/cleanup cron for `classification_decision` (trivial volume at
  current scale; revisit when it isn't).
- PostHog `classify.handled` enrichment.

---

## Part A — Port facet gate + origin into the TS scoring stage

All gate/org-key semantics stay single-sourced in SQL
(`thread_facets_gated()`, `connection_org_key()` in
`libs/db/schema/60-functions/`); TS calls them via `ctx.rawQuery` and
never reimplements the rules.

### A1. Candidate type extensions (`libs/classifier/src/types.ts`)

```ts
export interface Candidate {
  // ...existing fields...
  /** thread.facets (format/automation/reach). Null ⇒ gate fails open. */
  facets: Record<string, string> | null;
  /**
   * Originating connection (twist_instance id) — thread.created_by when
   * thread.twist_id is set, else null. Pre-insert callers pass what they
   * know; null disables the origin term for the candidate.
   */
  connectionId: string | null;
}
```

`buildCandidate` in `workers/api/src/state/classify-thread.ts` extends its
hydration query with `t.facets` and `t.twist_id` (connectionId =
`created_by` when `twist_id IS NOT NULL`). Pre-insert callers
(`thread-helpers.ts` `prepareThreadForDb`) pass the twist-instance id and
any facets available on the NewThread; the eval harness passes nulls until
the corpus models these (signals inert — same as today).

### A2. Origin signal (`ts-hybrid-scoring.ts`)

Mirrors `classify_thread_for_user.sql:243-246` ("origin rides inside the
combined score"):

1. Neighbor query gains
   `CASE WHEN mt.twist_id IS NOT NULL THEN mt.created_by END AS conn_id`.
2. One additional query resolves
   `public.connection_org_key(conn_id)` for the distinct neighbor
   conn_ids plus `candidate.connectionId`. Skipped entirely when the
   candidate has no `connectionId` (origin = 0 everywhere).
3. Per neighbor:
   `origin = exact` when `neighbor.conn_id === candidate.connectionId`,
   else `org` when both org keys are non-null and equal, else 0.
4. `origin` is added to the per-neighbor `combined` **before**
   `aggregateNeighbors` — the same position as SQL. It is an additive
   bonus, NOT part of the normalized `SignalWeights` (no change to
   `assertValidWeights`).
5. `ScoringExplain.topNeighbors` entries gain an `origin` field.

New `HybridParams` field (`ts-hybrid.defaults.ts`):

```ts
/**
 * Per-neighbor additive bonus when a user_moved example came from the
 * same connection (exact) or the same org (org), mirroring the SQL
 * scorer's 0.18/0.09. NOTE: topk_mean aggregation divides by k, so the
 * post-aggregation effect is ~1/k of the SQL constants — these defaults
 * are a starting point to be tuned once the eval corpus models
 * connections. Set both to 0 to disable.
 */
originBonus: { exact: number; org: number };
```

Default in `DEFAULTS` (inherited by `DEFAULTS_LLM`):
`{ exact: 0.18, org: 0.09 }`.

### A3. Facet gate (`ts-hybrid-scoring.ts`)

Mirrors `classify_thread_for_user.sql:318-325`. Scope matches SQL
semantics exactly: **only the scoring stage is gated.** Structural stages
(priority_prefix, keyed_priority, topic, channel_default), shortcuts, and
cold-start stay ungated. The LLM tie-breaker draws its candidate list from
the scoring stage's ranking, so it inherits the gate automatically.

Placement: after the `merged` per-priority ranking is built and sorted,
one batched query evaluates the gate over the ranked priority ids:

```sql
SELECT pid, public.thread_facets_gated($1, $2::jsonb, $3, pid) AS gated
FROM unnest($4::uuid[]) AS pid
```

(`$2` = candidate.facets, `$3` = candidate.author). Gated priorities are
removed from the ranking before the threshold/margin checks, so a gated
top-1 falls through to the next candidate, and a fully-gated ranking
falls through the cascade exactly like a no-match (shortcuts → cold-start
→ root). Run the query whenever the ranking is non-empty — it cannot be
skipped on `facets IS NULL` alone because `trustedSendersOnly` gates
regardless of facets, and `thread_facets_gated` returns immediately for
priorities with null `facet_filters`, so the always-run cost is one cheap
batched call.

`ScoringExplain` gains `facetGated?: string[]` (the dropped priority ids)
for debuggability; gated entries are excluded from `perPrioritySorted`.

### A4. Verification

- New vitest cases in `libs/eval/tests/` (where ts-hybrid tests live),
  using the existing sandbox-style harness: origin arithmetic
  (exact/org/none, aggregation interaction), gate-drops-winner →
  next-best wins, fully-gated → falls through to cold-start path,
  trusted-sender bypass (seeded `user_moved` row makes
  `is_trusted_for_focus` true), null-facets fail-open.
- Kris corpus re-run must be **score-identical** for
  `ts:hybrid-llm:default` (corpus has no facet_filters/connections ⇒ both
  new signals inert). This is the fail-open regression check.

---

## Part B — `classification_decision` log

### B1. Table (`libs/db/schema/50-tables/`, expand migration)

```sql
CREATE TABLE public.classification_decision (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    thread_id uuid NOT NULL,
    user_id uuid NOT NULL,
    priority_id uuid,                          -- chosen filing; NULL only for stage='none'
    stage text NOT NULL,                       -- cascade stage | 'sql:<stage>' | 'user_move'
    scores jsonb NOT NULL DEFAULT '{}',        -- ClassificationResult.scores / SQL explain payload
    classifier text NOT NULL,                  -- 'ts:hybrid-llm:production@<paramsHash>' | 'sql:classify_thread_for_user' | 'user'
    llm_calls int NOT NULL DEFAULT 0,
    cache_hits int NOT NULL DEFAULT 0,
    budget_exhausted boolean NOT NULL DEFAULT false,
    duration_ms real,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX classification_decision_user_thread_idx
    ON public.classification_decision (user_id, thread_id, created_at);
```

Deliberate properties:

- **Append-only, no FKs.** No lock coupling with the deadlock-sensitive
  `thread`/`thread_priority` write paths (see libs/db/AGENTS.md deadlock
  warning); rows survive any future cleanup of referents.
- **Not synced.** No `user.*` view, never reaches clients; the
  archived_at/seq sync rules do not apply. Bare DELETEs (future retention)
  are safe.
- **Readonly-readable.** Global default privileges already grant readonly
  SELECT on new tables (verify against `10-settings/80-grants.sql` during
  implementation) — required for prod mining via the readonly proxy.

### B2. Writers — log only where a decision is *applied*

Previews are never logged: `/sync/priority-match` and
`classifyThreadForUserExplain` (admin/debug) stay unlogged.

1. **API worker choke point** — `classifyThreadForUser`
   (`workers/api/src/state/classify-thread.ts`), immediately after
   `classifier.classify()` returns. Covers capture, `/sync/threads`
   auto_file, and twist thread-helpers. This is where stage/scores are
   currently discarded. The catch path (transient failure → root +
   pending) is **not** logged — no decision was made; the queue retry
   logs when it settles.
   **Pre-insert callers** (twist `prepareThreadForDb`, which classifies
   before the thread row exists) cannot be logged at the choke point —
   there is no thread_id yet. For those, `ClassifyResult` carries the
   decision entry back as `pendingLog`, threaded through
   `PreparedThread.pendingDecision`, and `createThread`/`createThreads`
   write it once the row exists. Because `upsert_thread` can merge into
   an existing thread (source match), the write is guarded by a
   created-at freshness check so merged threads don't get a spurious
   decision row. The "no match" path IS logged exactly as the
   classifier returned it: stage `none`, `priority_id` NULL. (The root
   filing the caller then applies is a fallback, recoverable from the
   stage — do not substitute it into the logged row.)
2. **Classify worker** — `workers/classify/src/handler.ts`, where the
   consumer settles a pending row with its ClassificationResult.
3. **SQL trigger paths** — `INSERT INTO classification_decision` added at
   the three apply sites (`file_thread_priority_on_group_member_change`
   INSERT branch, `file_thread_priority_on_topic_member_change`,
   `apply_channel_default`), with
   `classifier = 'sql:classify_thread_for_user'`. Log **only rows
   actually applied**: use `INSERT ... RETURNING` / `UPDATE ... RETURNING`
   CTEs so conflict-skipped rows (e.g. re-join un-revoke, which preserves
   prior filing) produce no decision row. Stage: `'sql:applied'`.
   Nice-to-have, only if it doesn't complicate the set-based statements:
   switch these call sites to `classify_thread_for_user_explain` via
   `CROSS JOIN LATERAL` to capture real stage (`'sql:' || stage`) and
   scores.
4. **User corrections** — `POST /sync/priority-moves`
   (`workers/api/src/app/sync/priority-moves.ts`): after the
   thread_priority upsert, same `withUserDb` transaction, insert
   `stage = 'user_move'`, `classifier = 'user'`,
   `priority_id = <move target>`, `scores = '{}'`.

### B3. Classifier versioning

`paramsHash` = short sha256 of canonical JSON (sorted keys) of the
resolved `HybridParams` — including prompt template ids and model —
computed once in the classifier-runtime factory
(`libs/classifier-runtime/src/factory.ts`) and stamped into the
`classifier` column (`ts:hybrid-llm:production@<hash>`). Weight, prompt, or
model changes become visible in the log without schema changes.

### B4. Error handling

- TS log writes: awaited insert wrapped in try/catch; on failure call
  `captureException` and continue — a logging failure must never fail or
  delay a filing. (Explicit handling per the error-capture rule, not
  fire-and-forget.)
- SQL trigger inserts: inline, no exception guard — a failed insert of
  this shape means the transaction has bigger problems.

### B5. What this unlocks (for the later eval workstream)

Labeled misclassifications via self-join per (user_id, thread_id): an
auto-decision row followed by a `user_move` row with a different
priority_id, with the auto row's top-k scores snapshot from decision
time. Mining caveat: low-confidence outcomes are asymmetric across
writers — TS paths log stage `none` with NULL priority_id (root fallback
not substituted), while the SQL trigger paths log `sql:applied` with the
root fallback already resolved; treat both as the "no confident match"
bucket. Live survival rate = fraction of auto decisions with no subsequent
`user_move`, per stage/classifier version. Seeder integration is
deferred.

---

## Rider

Flip the eval CLI default classifier from `sql:current` to
`ts:hybrid-llm:default` (`libs/eval/src/cli.ts`), so default eval runs
target what production runs. `sql:current` stays registered as a
comparison variant.

## Rollout / compatibility

- Single **expand** migration: new table + trigger-function updates
  (CREATE OR REPLACE). Purely additive; old workers ignore the table;
  migrations run before worker deploy. No contract phase.
- No Flutter/client involvement anywhere.
- All work local; user pushes/deploys.

## Testing

- **pgTAP** (`libs/db/tests/`): each of the three trigger paths writes a
  decision row on apply; conflict-preserved filings (group re-join
  un-revoke) write none; peer pending-row creation
  (`file_thread_priority_for_group_members`) writes none (it makes no
  decision).
- **workers/api vitest:** `classifyThreadForUser` logs stage/scores/
  classifier@hash on success, nothing on the catch path, and swallows +
  captures a failed log insert; `priority-moves` writes the `user_move`
  row.
- **libs/eval vitest:** Part A cases (A4).
- **Eval corpus:** kris re-run score-identical for `ts:hybrid-llm:default`
  (signals inert without corpus support) — fail-open proof.
