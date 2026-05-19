# Hybrid Classifier — Production Wiring Design

**Status:** Draft
**Date:** 2026-05-18
**Spec for:** Replacing the production thread classifier (the PostgreSQL function `classify_thread_for_user_explain` and its `classify_thread_for_user` wrapper) with the `ts:hybrid-llm` classifier implemented in `libs/eval/src/classifiers/`. All classification is orchestrated from the API; SQL helpers stay for set-based candidate prefiltering but no longer classify. Postgres triggers no longer call the classifier. Cut-over is direct (no per-user feature flag); rollback is `git revert`.

**Prior spec:** `docs/superpowers/specs/2026-05-18-hybrid-thread-classifier-design.md` (designed and built `ts:hybrid-llm` inside `libs/eval/`; explicitly deferred production wiring).

---

## 1. Background

Today, every classification — whether triggered by a foreground API request, by a Postgres trigger inside the originating transaction, or by a bulk RPC — runs entirely inside PostgreSQL as `public.classify_thread_for_user_explain(...)`. The TS file `workers/api/src/state/classify-thread.ts` is a thin RPC wrapper. The classifier's input is `(user_id, thread_id[, embedding, topic, contacts, groups])` and its output is `(priority_id, stage, scores)`.

Callers, grouped by execution origin:

| Path | Originates in | Runs in | Notes |
|---|---|---|---|
| `workers/api/src/app/sync/capture.ts:113` | API | PG RPC | Foreground; user just hit save |
| `workers/api/src/app/sync/threads.ts:463` | API | PG RPC | Foreground; `auto_file` on upsert |
| `workers/api/src/twist/tools/plot/thread-helpers.ts:1128` | API | PG RPC | Twist-created thread |
| `workers/api/src/twist/dev-activities.ts:157/163/173/174` | API | Raw SQL | Dev seeders only |
| `95-triggers/22-thread_priority_peers.sql:57` | DB trigger | PG | Per-peer fan-out on `INSERT` `thread` |
| `95-triggers/23-thread_group_peers.sql:37/88` | DB trigger | PG | Per-member fan-out on `INSERT` `thread_group` and on `group_member` changes |
| `95-triggers/18-thread_topic_from_channel.sql:63` | DB trigger | PG | Re-class on `thread.topic` change |
| `90-user-schema/80-upsert_thread.sql:533/580` | API → DB | PG | Peer paths inside `user.upsert_thread` RPC |
| `60-functions/reclassify_user_threads.sql:124` | API → DB | PG | Bulk re-class after a user move (called from `priority-moves.ts:60`) |
| `60-functions/apply_channel_default.sql:82` | API → DB | PG | Bulk re-class after a channel's `default_priority_id` changes (called from `channel-router.ts:304`) |

### Why we have to move

- `ts:hybrid-llm` requires LLM calls, file system I/O for the prompt cache, and a Node-only HTTP stack. Cloudflare Workers can run the calls, but neither Postgres nor the Worker can run the file-cached Node version directly.
- Trigger-driven classification is inside the originating transaction; a Worker round-trip there is structurally impossible and an LLM call's tail latency (seconds on cache miss) would be intolerable anyway.
- A wholesale "run TS classifier in PG" port is infeasible (no embeddings/LLM/HTTP in `plpgsql`).

The shape of the solution: keep `INSERT`/`UPDATE` transactions short, mark the rows that still need classifying, and let a Worker drain them.

---

## 2. Goals and non-goals

### Goals

- Every classification call site moves to the Worker-side `ts:hybrid-llm` classifier.
- All orchestration originates in the API. Triggers become bookkeeping (no classifier calls). No new outbox table.
- Threads remain invisible to peer users until classification has actually resolved (success), or until the 5-minute view-fallback window elapses (root, recoverable later by the sweep).
- Existing-priority rows (`reclassify` cases) never bounce through root or any intermediate state.
- Every queued classification gets at least one attempt. On transient failure, the row stays pending and the hourly sweep retries indefinitely; on permanent failure the operator is alerted and intervenes. Nothing strands silently — `classify_at` is durable and the sweep is the floor.
- Zero schema or API changes visible to the Flutter app. Drift schema unchanged. `/sync/*` payload shapes unchanged.

### Non-goals

- Tuning `ts:hybrid-llm` parameters (the prior spec covers that; we ship today's defaults).
- Per-user feature flag for staged rollout (rejected — replace outright; `git revert` is the rollback).
- Eliminating the `thread_priority` table (the per-user filing relation stays).
- Re-architecting the Flutter sync protocol.

---

## 3. Architecture

```
                 ┌────────────────────────────────────────┐
   user request →│ workers/api                            │
                 │  · foreground: classifier.classify()   │ (capture, sync/threads, twist-create)
                 │    → INSERT thread_priority(priority_id, classify_at=NULL)
                 │    on failure: priority_id=root, classify_at=now() (consumer retries)
                 │  · enqueue ClassifyJob[] per peer/reclass target ──┐
                 └────────────────────────────────────────────────────┼─┐
                                                                      ▼ │
                                                       ┌────────────────┴──────┐
                                                       │ Cloudflare Queue:     │
                                                       │  classify-thread      │ (max_retries=4, no DLQ handler)
                                                       └──────┬────────────────┘
                                                              ▼
                                                       ┌─────────────────────────┐
                                                       │ workers/classify        │ (new consumer Worker)
                                                       │  classifier.classify()  │
                                                       │  → UPDATE thread_priority
                                                       └─────────────────────────┘
                                                              ▲
                                                              │
   ┌──────────────────────────┐                               │
   │ recovery sweep (hourly)  │ ──── SELECT WHERE classify_at < now() - 1 hour → re-enqueue
   │ + manual admin trigger   │      (primary recovery for retry-exhausted rows)
   └──────────────────────────┘

   View-fallback (5 min) covers user visibility during outages: rows with
   priority_id NULL and classify_at older than 5 min surface at root via
   COALESCE in user.* views — no DB write required.

   Shared core (libs/classifier):
     · stages, scoring, defaults, ts-hybrid-llm orchestrator
     · LLMClient interface (no fs / no env access)

   Worker-side adapters (libs/classifier-runtime, shared by both Workers):
     · kvLlmCache(env.LLM_CACHE)            → KV-backed LLMClient wrapper
     · kvBudget(env.LLM_CACHE)              → KV-backed daily per-user budget
     · workerGeminiClient(env.GOOGLE_GENERATIVE_AI_API_KEY)
     · classifierContextFromDb(db, userId)  → ClassifierContext over a given Kysely handle
     · canonicalInput(...)                  → deterministic cache-key serializer
```

### State machine on `thread_priority`

Two columns carry the entire async pending state — no new table.

| `priority_id` | `classify_at` | Meaning | User sees |
|---|---|---|---|
| set | NULL | Settled | At `priority_id` |
| set | NOT NULL | Reclassify pending (cases B–D, including foreground-failure author rows) | At current `priority_id` (no bounce) |
| NULL | NOT NULL (≤ 5 min) | Initial classify pending (case A) | Hidden |
| NULL | NOT NULL (> 5 min) | Retry in progress; view fallback active | At root (view fallback) |
| NULL | NULL | Forbidden by CHECK constraint | — |

The 5-minute view fallback is the bulletproof floor: even if the entire classifier pipeline is down, every thread becomes visible at root within 5 minutes of arrival.

A row in the (NULL, NULL) state would be permanently invisible and unrecoverable by the sweep. A `CHECK (priority_id IS NOT NULL OR classify_at IS NOT NULL)` constraint (§4) prevents this state from ever being written.

### Why no outbox table

A separate `thread_classification_pending` table would require: (a) trigger writes there instead of `thread_priority`; (b) the consumer migrates rows from pending into `thread_priority`; (c) thread_unread coordination; (d) a sync-seq bump on the migration. Folding the pending marker into `thread_priority` itself (`priority_id NULL` + `classify_at NOT NULL`) eliminates all of that. Visibility logic stays in one place. Trigger writes are unchanged in shape — only the values written change. `thread_unread` rows can be inserted by triggers as before because they remain harmless while the parent row is hidden.

---

## 4. Schema changes

```sql
-- libs/db/schema/50-tables/27-thread_priority.sql
ALTER TABLE public.thread_priority
    ALTER COLUMN priority_id DROP NOT NULL,
    ADD COLUMN classify_at timestamptz NULL,
    ADD CONSTRAINT thread_priority_state_valid
        CHECK (priority_id IS NOT NULL OR classify_at IS NOT NULL);

CREATE INDEX thread_priority_classify_pending_idx
    ON public.thread_priority (classify_at)
    WHERE classify_at IS NOT NULL;

COMMENT ON COLUMN public.thread_priority.priority_id IS
'User''s priority filing. NULL means classification is pending (see classify_at). Views must use COALESCE(priority_id, root_priority_id(user_id)) to display, gated by the visibility filter (priority_id IS NOT NULL OR classify_at < now() - interval ''5 minutes'').';

COMMENT ON COLUMN public.thread_priority.classify_at IS
'Timestamp when classification was last requested. NULL once classification has succeeded. NOT NULL signals the consumer Worker to (re-)classify this row.';
```

Backfill: existing rows are settled. `priority_id` is set; `classify_at` defaults to NULL. No data migration required.

### Affected `user.*` views

A single SQL helper centralizes the 5-minute window so it can be tuned in one place:

```sql
-- libs/db/schema/60-functions/classify_visibility_window.sql
CREATE OR REPLACE FUNCTION public.classify_visibility_window ()
RETURNS interval
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT interval '5 minutes' $$;
```

Every view that joins `thread_priority` and either filters on `priority_id` or exposes it to clients applies the same pattern:

```sql
JOIN public.thread_priority tp ON tp.thread_id = t.id

-- visibility filter
AND (tp.priority_id IS NOT NULL
     OR tp.classify_at < now() - public.classify_visibility_window())

-- effective priority for any column the view exposes:
COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
```

Inventoried (plan task to grep `thread_priority` across `libs/db/schema/90-user-schema/` and update each):
- `user.thread`
- `user.priority`
- `user.priority_unread`
- Any other view in `90-user-schema/` referencing `thread_priority`.

The Flutter app reads `priority_id` from `user.thread` as a non-null denormalized column (`apps/plot/lib/store/thread.dart:29` confirms this is the only path). The `COALESCE` keeps the column non-null from the client's point of view; the visibility filter keeps hidden rows out of the client's view entirely.

### Sync-seq bump

The "Bump Parent `seq` on Child-Table Changes" pattern (`libs/db/AGENTS.md`) applies: when a `thread_priority` row's `priority_id` changes, sync must re-emit the parent thread to clients that already pulled it. Implemented as a trigger so every caller — consumer Worker, sweep-driven retry, future code — is covered uniformly:

```sql
-- libs/db/schema/95-triggers/24-thread_priority_bump_parent.sql
CREATE OR REPLACE FUNCTION public.bump_thread_seq_on_priority_change ()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE public.thread SET updated_at = now() WHERE id = NEW.thread_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER thread_priority_bump_parent
AFTER UPDATE OF priority_id ON public.thread_priority
FOR EACH ROW
WHEN (NEW.priority_id IS DISTINCT FROM OLD.priority_id)
EXECUTE FUNCTION public.bump_thread_seq_on_priority_change();
```

The trigger only fires on actual `priority_id` changes. The consumer's "same result" branch (clears `classify_at` only) does not bump and does not trigger needless client re-sync. `classify_at` is internal-only and never exposed to clients, so it is excluded from the bump condition.

---

## 5. Trigger changes

Triggers retain their fan-out responsibility (who needs a `thread_priority` row) but stop calling the classifier. Each becomes a single set-based statement.

### `95-triggers/22-thread_priority_peers.sql`

```sql
-- file_thread_priority_peers(): on AFTER INSERT/UPDATE OF contacts ON thread
INSERT INTO public.thread_priority (thread_id, user_id, priority_id, classify_at)
SELECT NEW.id, peer.user_id, NULL, now()
FROM (
    SELECT DISTINCT uc.user_id
    FROM unnest(NEW.contacts) c(contact_id)
    JOIN public.user_contact uc
      ON uc.contact_id = c.contact_id
     AND uc.linked = TRUE
     AND uc.archived_at IS NULL
    WHERE uc.user_id IS DISTINCT FROM NEW.created_by
) peer
ON CONFLICT (thread_id, user_id) DO NOTHING;
```

`thread_unread` insertions stay as today (newly-added contacts only on UPDATE; all peers on INSERT). They are harmless while the parent thread_priority row is hidden.

The "only for user-authored threads" guard (`EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by)`) stays in place — twist-authored threads continue to file peers only via their own connector's `upsert_thread` call.

### `95-triggers/23-thread_group_peers.sql`

Both `file_thread_priority_for_group_members` (on `thread.groups` change) and `file_thread_priority_on_group_member_change` (INSERT branch on `group_member`) follow the same pattern — single `INSERT … SELECT` of pending rows; classifier call removed; `thread_unread` insert unchanged. The DELETE branch on `group_member` is untouched (it removes existing rows; no classification involved).

### `95-triggers/18-thread_topic_from_channel.sql`

The trigger replaces its per-user loop with a single statement that marks affected rows for reclassification:

```sql
UPDATE public.thread_priority
SET classify_at = now()
WHERE thread_id = NEW.thread_id
  AND priority_id IS NOT NULL          -- only mark settled rows; pending stays pending
  AND user_moved = FALSE;              -- sticky rows are never reclassified
```

### `90-user-schema/80-upsert_thread.sql`

The two classifier-calling paths inside `user.upsert_thread`:

- **Pending-contacts peer block (lines 517–545):** classifier call dropped; the existing `INSERT INTO thread_priority` becomes the same pending-marker pattern (`priority_id = NULL, classify_at = now()`). The `applied_default_channel_id` column is set to NULL here — the consumer recomputes via `channel_default_marker(...)` when it writes the final priority.
- **Cross-user keyed-priority block (lines 556–595):** classifier call dropped; same pending-row pattern.

The author's row (lines ~468) is unchanged. The API caller passes a resolved `priority_id` for the author; the SQL just inserts it.

### Dispatch from API

Any API path that triggers pending-row creation must enqueue jobs before returning. A single helper in `workers/api/src/state/classify-thread.ts`:

```ts
// Cloudflare Queues caps sendBatch at 100 messages — mirror the chunking
// already used in workers/mailer/src/index.ts:117-128.
const QUEUE_BATCH_SIZE = 100;

async function enqueueJobs(env: Env, jobs: ClassifyJob[]): Promise<void> {
  if (jobs.length === 0) return;
  const batches: ClassifyJob[][] = [];
  for (let i = 0; i < jobs.length; i += QUEUE_BATCH_SIZE) {
    batches.push(jobs.slice(i, i + QUEUE_BATCH_SIZE));
  }
  await Promise.all(
    batches.map((batch) =>
      env.QUEUE_CLASSIFY.sendBatch(batch.map((body) => ({ body })))
    )
  );
}

async function dispatchPendingForThread(
  db: Kysely<DB>, env: Env, threadId: string,
): Promise<void> {
  const rows = await db.selectFrom("thread_priority")
    .select(["user_id"])
    .where("thread_id", "=", threadId)
    .where("classify_at", "is not", null)
    .execute();
  await enqueueJobs(env, rows.map((r) => ({ userId: r.user_id, threadId })));
}
```

**Dispatch ordering — single rule:** dispatch runs *after* the route's transaction has committed, using `c.executionCtx.waitUntil`. The pending rows must be visible to the SELECT inside `dispatchPendingForThread`, which they are not until commit. Inside `waitUntil`, the per-request `c.var.db` handle is already destroyed (see CLAUDE.md "never use `c.var.db` inside `waitUntil`"), so the helper opens a fresh connection:

```ts
// In each call site, after the withUserDb block returns:
c.executionCtx.waitUntil((async () => {
  const db = createDb(c.env);
  try {
    await dispatchPendingForThread(db, c.env, threadId);
  } finally {
    await db.destroy();
  }
})());
```

If `waitUntil` is cut off (Worker eviction) or the dispatch DB call itself fails, the pending rows remain in place and the hourly sweep (§7) picks them up on the next tick. No row is ever stranded by a dispatch failure.

Call sites:

| Trigger event | API caller that dispatches |
|---|---|
| `INSERT thread` (capture / sync/threads / twist create) | The route handler after the foreground author classification |
| `UPDATE thread.contacts` | The route handler that updates contacts |
| `UPDATE thread.groups` / `group_member` change | The route handler (or, for `group_member`, the membership-change handler) |
| `UPDATE thread.topic` from channel-default flow | `channel-router.ts` after the topic write |
| `user.upsert_thread` peer / keyed paths | The route handler that invoked `user.upsert_thread` |
| Bulk reclass (move / channel-default change) | `priority-moves.ts` and `channel-router.ts` after calling the SQL helpers |

Crash safety: if dispatch fails or the request crashes before dispatch runs, the pending row stays in place — the **sweep** (§7) will re-enqueue it.

---

## 6. Foreground classifier callsites

The synchronous (author / capture) path:

```ts
// workers/api/src/state/classify-thread.ts
export type ClassifyResult = { priorityId: string; pending: boolean };

export async function classifyThreadForUser(
  db: Kysely<DB>, env: Env, args: ClassifyArgs
): Promise<ClassifyResult> {
  try {
    const result = await getProductionClassifier(env).classify(
      classifierContextFromDb(db, args.userId),
      candidateFromArgs(args)
    );
    if (result.priorityId) return { priorityId: result.priorityId, pending: false };
    // Classifier returned no match: file at root, settled. This is a normal
    // result, not a failure — no async retry is warranted.
    return { priorityId: await rootPriorityId(db, args.userId), pending: false };
  } catch (err) {
    tracker.captureException(err);
    // Transient classifier failure (LLM timeout, network blip, etc.). File at
    // root for instant author visibility but mark pending so the consumer
    // re-attempts and corrects the placement when the classifier recovers.
    return { priorityId: await rootPriorityId(db, args.userId), pending: true };
  }
}
```

The author's `thread_priority` row is inserted with `priority_id = result.priorityId, classify_at = result.pending ? now() : NULL`. The user always sees their freshly-created thread immediately (no hidden state for the author), and on a transient failure the consumer Worker — driven either by the dispatch enqueue or the hourly sweep — eventually re-runs and may move the thread out of root. This mirrors the cases B–D pattern: settled at a priority, pending re-evaluation.

After a foreground failure, the caller MUST include the author's thread in the subsequent `dispatchPendingForThread(...)` call (the helper already selects all `classify_at IS NOT NULL` rows for the thread, so this is automatic — no extra plumbing).

**Return-type change:** the existing signature is `Promise<string | null>` (callers handle null and fall back to root themselves). The new wrapper always returns a non-null priority. Callers that handle null today simplify (no behavior change for them; they were already routing null → root). Plan task: audit each caller and remove the now-dead null branch, and thread the `pending` flag into the row insert.

Callers: `capture.ts:113`, `threads.ts:463`, `twist/tools/plot/thread-helpers.ts:1128` (invoked via `prepareThreadForDb`), and `twist/dev-activities.ts:*`. The body of `classifyThreadForUser` flips from `rpc("classify_thread_for_user")` to the new path.

The `match_priority_for_user(user_id)` single-arg variant called via `prepareThreadForDb` is replaced with the same TS path — the wrapper accepts the existing arg shape (`{ userId, threadId?, embedding?, topic?, contacts?, groups? }`) and works whether `threadId` is provided or not.

`classifyThreadForUserExplain` is reimplemented on the same Worker classifier and exposed only to internal/admin paths; production callers don't use it.

---

## 7. Consumer Worker

New Worker `workers/classify`, deployed alongside `workers/api`. Single producer (`workers/api`), single consumer.

### Wrangler bindings

```toml
# workers/api/wrangler.toml additions
[[kv_namespaces]]
binding = "LLM_CACHE"
id = "<llm-cache-namespace-id>"

[[queues.producers]]
queue   = "classify-thread"
binding = "QUEUE_CLASSIFY"

# workers/classify/wrangler.toml
[[queues.consumers]]
queue                = "classify-thread"
max_batch_size       = 10
max_batch_timeout    = 5
max_retries          = 4
# No dead_letter_queue: messages that exhaust retries are intentionally dropped.
# thread_priority.classify_at is the durable source of truth — the hourly
# sweep (§7 below) re-enqueues anything that didn't clear. See §7
# "Why no DLQ handler" for the rationale.
```

KV namespace `LLM_CACHE` holds both the response cache (`llm-classify:<promptId>:<sha256(input)>`, 30-day TTL) and the daily budget counter (`llm-budget:<userId>:<yyyymmdd>`, 24-hour TTL). No second namespace.

### Job shape

```ts
type ClassifyJob = { userId: string; threadId: string };
```

The kind (classify_new vs reclassify) is implicit: read `thread_priority.priority_id` at consume time and branch on whether it's NULL.

### Consumer handler

```ts
async function handle(job: ClassifyJob, env: Env, db: Kysely<DB>) {
  const row = await db.selectFrom("thread_priority")
    .select(["priority_id", "user_moved", "classify_at"])
    .where("user_id", "=", job.userId).where("thread_id", "=", job.threadId)
    .executeTakeFirst();

  if (!row || row.classify_at == null || row.user_moved) return; // already settled

  const snapshot = row.priority_id;                                // null = case A
  // Throws here propagate up so the queue retries; after max_retries the
  // message is dropped, but classify_at stays set and the hourly sweep
  // re-enqueues. The CHECK constraint guarantees the row is never (NULL, NULL).
  const result = await getProductionClassifier(env).classify(...);

  const target = result.priorityId
    ?? (snapshot ?? await rootPriorityId(db, job.userId));

  if (snapshot == null) {
    await db.updateTable("thread_priority")
      .set({ priority_id: target, classify_at: null })
      .where("user_id", "=", job.userId).where("thread_id", "=", job.threadId)
      .where("priority_id", "is", null).where("user_moved", "=", false)
      .execute();
  } else if (target !== snapshot) {
    await db.updateTable("thread_priority")
      .set({ priority_id: target, classify_at: null })
      .where("user_id", "=", job.userId).where("thread_id", "=", job.threadId)
      .where("priority_id", "=", snapshot).where("user_moved", "=", false)
      .execute();
  } else {
    await db.updateTable("thread_priority")
      .set({ classify_at: null })
      .where("user_id", "=", job.userId).where("thread_id", "=", job.threadId)
      .execute();
  }

  // No explicit thread.updated_at bump — the
  // thread_priority_bump_parent trigger (§4) fires automatically when
  // priority_id changes. The "same result" branch above (clearing
  // classify_at only) intentionally does not re-emit to clients.
}
```

### Why no DLQ handler

An earlier revision included a dead-letter consumer that, after queue retries exhausted, wrote the row to its final state: root for case A, leave-at-current for cases B–D. We removed it. Trade-off:

- **What it bought:** preventing the sweep from re-enqueuing chronically-failing rows hourly forever.
- **What it cost:** *every* transient classifier outage longer than the queue retry window (~5 min of backoff at `max_retries=4`) would permanently file case-A rows at root. A 20-minute LLM outage finalizes thousands of threads to root that the recovered classifier would have placed correctly. If the user then drags such a thread to a different priority, `user_moved=true`, and even an admin-triggered sweep can no longer fix the placement.

The 5-minute view fallback already provides user-visible recovery during outages; the sweep handles correctness recovery once the pipeline returns. Removing the DLQ handler keeps the option to classify correctly open indefinitely. The cost — bounded sweep thrash for genuinely permanent failures — is acceptable because (a) KV cache makes repeat attempts on identical inputs nearly free, (b) the per-user daily LLM budget caps spend, and (c) chronic failures are explicitly alarmed and require human intervention regardless.

If a chronic stuck row is identified, the operator's path is: fix the underlying bug, deploy, and either wait for the next sweep tick or hit `POST /admin/classify/sweep`. No DLQ-finalize step required.

### Recovery sweep (primary recovery for retry-exhausted rows)

Three safety nets in order of frequency:

1. **Cloudflare Queue retries** (up to `max_retries`, exponential backoff) — handles transient consumer failures within minutes.
2. **5-minute view fallback** — handles user-visible recovery: case A threads become visible at root within 5 minutes of the original `classify_at`, regardless of consumer state.
3. **Hourly sweep + admin trigger** — re-enqueues anything still pending after the queue gave up. This is the durable correctness net: it runs forever until either the consumer succeeds (clears `classify_at`) or the row is manually finalized via SQL.

Implementation:

- **Scheduled** — once an hour, via the existing cron Worker (or a new one if none exists). Picks up rows with `classify_at < now() - 1 hour` and re-enqueues. Bounded at 1000 rows per run; multiple runs drain larger backlogs.
- **Manual trigger** — `POST /admin/classify/sweep` (admin-only, gated by the existing admin-auth middleware in `workers/api`) runs the same scan immediately for operators to invoke after deploying a fix without waiting for the next hourly tick.

```ts
async function runSweep(db: Kysely<DB>, env: Env): Promise<{ enqueued: number }> {
  const stuck = await db.selectFrom("thread_priority")
    .select(["user_id", "thread_id"])
    .where("classify_at", "is not", null)
    .where("classify_at", "<", sql`now() - interval '1 hour'`)
    .orderBy("classify_at", "asc")   // oldest first
    .limit(1000).execute();

  await enqueueJobs(env, stuck.map((r) => ({ userId: r.user_id, threadId: r.thread_id })));
  return { enqueued: stuck.length };
}
```

The sweep does not update `classify_at` — it stays the original "requested at" timestamp so the view fallback's age check remains meaningful. The sweep uses the shared `enqueueJobs` helper (§5) so chunking by 100 is automatic.

### Error reporting

Failures must be loud — operators have to notice a deployed bug or chronic issue.

- **Consumer thrown exceptions** — `tracker.captureException(err, { userId, threadId, kind })` in the consumer's catch block before re-throwing for queue retry. PostHog deduplicates; persistent failures surface as a high-count issue.
- **Pending-row gauge** — periodic count of `thread_priority WHERE classify_at IS NOT NULL`, emitted as a PostHog metric from the hourly sweep job. Steady-state should be near zero; sustained non-zero is the leading indicator of a degradation.
- **Sweep results** — log `{ enqueued, oldest_classify_at }` from each scheduled run. Alert on **growth or sustained volume**, not on any non-zero value: a single chronic row should not page. Concretely: alert when `enqueued > 100` for ≥2 consecutive hours, OR when `oldest_classify_at` exceeds 6 hours (anything older than 6 sweep cycles is genuinely stuck and not just retrying).
- **View-fallback hit rate** — query/metric to count how many rows the visibility view is currently surfacing via the root-fallback branch (`priority_id IS NULL AND classify_at < now() - interval '5 minutes'`). Any non-zero value means users are seeing the recovery behavior in real time; sustained non-zero indicates the foreground classifier is failing for new threads.
- **Foreground-failure rate** — count of rows written by `classifyThreadForUser` with `pending=true`. Steady-state should be ~0 (transient errors only). A spike means the foreground classifier is degraded and the consumer is absorbing extra load.

---

## 8. Bulk paths

The two existing bulk SQL functions become non-classifying SQL helpers that mark and return:

```sql
-- libs/db/schema/60-functions/mark_reclassify_candidates.sql
CREATE OR REPLACE FUNCTION public.mark_reclassify_candidates (
    p_user_id          uuid,
    p_anchor_thread_id uuid
) RETURNS TABLE (user_id uuid, thread_id uuid)
LANGUAGE sql AS $$
    UPDATE public.thread_priority tp
    SET classify_at = now()
    FROM (/* same candidate prefilter CTEs from the old reclassify_user_threads */) c
    WHERE tp.user_id = p_user_id
      AND tp.thread_id = c.thread_id
      AND tp.user_moved = FALSE
      AND tp.priority_id IS NOT NULL
    RETURNING tp.user_id, tp.thread_id;
$$;
```

```sql
-- libs/db/schema/60-functions/mark_channel_default_candidates.sql
CREATE OR REPLACE FUNCTION public.mark_channel_default_candidates (
    p_channel_id bigint
) RETURNS TABLE (user_id uuid, thread_id uuid)
LANGUAGE sql AS $$
    UPDATE public.thread_priority tp
    SET classify_at = now()
    FROM (/* same candidate prefilter from the old apply_channel_default */) c
    WHERE tp.user_id = c.user_id AND tp.thread_id = c.thread_id
      AND tp.user_moved = FALSE
      AND tp.priority_id IS NOT NULL
    RETURNING tp.user_id, tp.thread_id;
$$;
```

API callers (`priority-moves.ts:60`, `channel-router.ts:304`) replace the existing `rpc("reclassify_user_threads", …)` / `rpc("apply_channel_default", …)` with: call the new helper, then pass the returned rows to the chunked `enqueueJobs` helper (§5). The originating user's request returns immediately. Channel-default and priority-move flows can mark thousands of rows at once; **direct `sendBatch` here would silently fail at the Cloudflare 100-message cap** — `enqueueJobs` is mandatory.

`reclassify_user_threads`, `apply_channel_default`, `classify_thread_for_user`, `classify_thread_for_user_explain`, and `match_priority_for_user` are dropped in a follow-up migration once the new code is deployed and no SQL caller references them.

---

## 9. The `libs/classifier` package

Extract from `libs/eval/src/classifiers/`:

- `ts-hybrid-llm.ts`, `ts-hybrid.ts`, `ts-hybrid.defaults.ts`, and all `ts-hybrid-*.ts` (stages, scoring, signals, shortcuts, tie-breaker, cold-start, topic-llm, accounts, aggregate)
- `llm-client.ts` (interface only — the Gemini constructor stays in `libs/eval` since it pulls Node env)
- `prompts/*.txt` + `prompts/index.ts` (text loader — Workers esbuild supports `import txt from "./foo.txt"` with the right loader config)
- `types.ts` (`ClassifierContext`, `Classifier`, `Candidate`, `ClassificationResult`)

`libs/eval` re-exports its own Node-side concerns: `makeGeminiClient`, `cachedLlmClient` (file cache), and the eval-specific registry/runner/CLI.

### Shared Worker-runtime adapters

The Worker-side adapters are consumed by **both** `workers/api` (foreground classify + dispatch) and `workers/classify` (consumer). To avoid cross-Worker imports, they live in their own workspace package `libs/classifier-runtime/`:

```
libs/classifier-runtime/
  src/
    kv-cache.ts            — KV-backed LLMClient wrapper
    kv-budget.ts           — per-user daily LLM budget counter
    worker-gemini-client.ts — @ai-sdk/google adapter (uses env.GOOGLE_GENERATIVE_AI_API_KEY)
    factory.ts             — getProductionClassifier(env) cached singleton
    context.ts             — classifierContextFromDb(db, userId)
    canonical-input.ts     — input canonicalization for cache keys (below)
  package.json             — exports the above; no Node-only deps
```

Both `workers/api` and `workers/classify` declare `@plotday/classifier-runtime` as a workspace dependency. `libs/classifier-runtime` depends on `@plotday/classifier` (pure orchestration, no I/O).

### KV cache key canonicalization

The cache key is `llm-classify:<promptId>:<sha256(canonicalInput)>`, TTL 30 days. Hit rate depends entirely on `canonicalInput` being deterministic for inputs that should be treated as equivalent. `canonical-input.ts` is the single source of truth:

```ts
export function canonicalInput(prompt: string, ctx: SerializedContext, cand: Candidate): string {
  // ordered keys, no whitespace; arrays sorted by stable id
  return JSON.stringify({
    p: prompt,
    c: {
      userId: ctx.userId,
      topic: cand.topic ?? null,
      contacts: [...(cand.contacts ?? [])].sort(),    // uuid arrays sorted lexicographically
      groups:   [...(cand.groups ?? [])].sort(),
      // embedding: half-precision floats rounded to 4 decimal places
      embedding: cand.embedding?.map((x) => Number(x.toFixed(4))) ?? null,
      // priorities snapshot: id + key only (stable across re-renders);
      // ordered by id so view re-orderings don't bust the cache
      priorities: ctx.priorities.map((p) => ({ id: p.id, key: p.key }))
                                .sort((a, b) => a.id.localeCompare(b.id)),
    },
  });
}
```

Rules:
- All UUID arrays are sorted before serialization.
- Embedding floats are rounded to 4 decimals (consistent with the eval-side hashing already in use; see `libs/eval/src/classifiers/ts-hybrid-llm.ts`).
- The thread title/notes are **not** part of the input — the embedding is the canonical content fingerprint.
- `Date` fields, if any, are coerced to ISO strings.
- The serialized form must be byte-identical between the foreground Worker and the consumer Worker; a single test (`canonical-input.test.ts`) asserts both call sites produce the same bytes.

`promptId` increments any time the prompt template or canonicalization rules change, invalidating the existing cache wholesale.

### Removed Node-specific code

`ts-hybrid-llm.ts:32-33` (`dirname`/`fileURLToPath`/`CACHE_DIR`) is deleted. The eval-side cache directory is computed in the eval registry instead.

---

## 10. Decommission

Once the new code is deployed and the sweep confirms zero rows referencing the old paths:

- Drop the SQL functions: `classify_thread_for_user`, `classify_thread_for_user_explain`, `match_priority_for_user`, `reclassify_user_threads`, `apply_channel_default`.
- Delete `workers/api/src/state/classify-thread.ts`'s `Explain` export if unused.
- Eval-side `sql:current` classifier (`libs/eval/src/classifiers/sql-current.ts`) is retained — eval needs to compare against the old behavior historically, and a frozen schema dump is reasonable. (Plan task: confirm or also delete.)

### Caller replacements that are not pure wrapper swaps

Two callers use the old classifier in shapes that are not a 1:1 wrapper swap and need explicit replacement design:

**`workers/api/src/twist/tools/integrations.ts:1138` (and `thread-helpers.ts:1128`)** — currently calls `rpc("match_priority_for_user", { p_user_id })` (the single-arg variant) via `prepareThreadForDb`. The new `classifyThreadForUser` accepts the same arg shape; this is the cleanest replacement. The "no threadId yet" case (pre-insert) feeds `embedding/topic/contacts/groups` directly. The plan task is to verify every twist-side path uses the new wrapper and the `pending` flag is propagated into the row insert for failure-mode correctness.

**`workers/api/src/twist/dev-activities.ts:157/163/173/174`** — these use `classify_thread_for_user(...)` as a SQL expression inside `WHERE` clauses (e.g. `WHERE classify_thread_for_user(uc.user_id, ${threadRow.id}::uuid) IS NOT NULL`), filtering rows by classification result inside a single SQL statement. There is no equivalent TS expression. Replacement: in dev-seeder code, hoist the classification to a TS loop — for each candidate row, call `classifyThreadForUser` and conditionally proceed. This is dev-only seeding (per file comment); a small perf regression is acceptable. Plan task to implement and confirm the seeders still produce equivalent test fixtures.

---

## 11. Testing

- **Unit tests on Worker adapters** (`kv-cache.ts`, `kv-budget.ts`, `canonical-input.ts`) using `@cloudflare/workers-types` test helpers.
- **Canonicalization parity:** `canonical-input.ts` test asserts the foreground call site and the consumer call site produce byte-identical serialized bytes for the same logical input (regression guard against cache misses caused by drift between Workers).
- **Unit tests on the consumer handler:**
  - Case A success → row updated with classified priority, `classify_at` cleared, parent thread seq bumped via trigger.
  - Case A on classifier returning null → root fallback.
  - Case B–D success with different result → guarded UPDATE (snapshot-matching WHERE) writes new priority, trigger bumps parent.
  - Case B–D success with same result → only `classify_at` cleared, **trigger does not fire** (assert no `thread.updated_at` change).
  - `user_moved` set between enqueue and consume → no-op.
  - Classifier throws → handler re-throws (queue retries).
- **Foreground failure test:** `classifyThreadForUser` with classifier throwing → returns `{ priorityId: root, pending: true }`; the call-site row insert writes `classify_at=now()` and the dispatch enqueues the row; the consumer corrects the placement on its next attempt.
- **Sweep test:** stuck rows older than 1 hour → enqueued; fresh rows → ignored; result chunked correctly when >100 rows. Manual admin trigger returns enqueued count and is gated by admin auth (401 for non-admins).
- **`enqueueJobs` chunking test:** 250-row input → 3 `sendBatch` calls of sizes 100/100/50; 0-row input → no calls.
- **Bulk path test:** `mark_reclassify_candidates` + dispatch over a 1500-row candidate set → all rows enqueued (no silent loss).
- **DB CHECK constraint test:** attempting `INSERT thread_priority(priority_id=NULL, classify_at=NULL)` raises `thread_priority_state_valid` violation. Same for `UPDATE` setting both to NULL.
- **Parent-seq trigger test:** `UPDATE thread_priority SET priority_id=X` where X ≠ OLD fires the trigger and bumps `thread.updated_at`; `UPDATE thread_priority SET classify_at=NULL` (no priority change) does NOT bump.
- **Error reporting test:** consumer throw → `captureException` called with `{userId, threadId, kind}`; foreground failure → `captureException` called and the resulting row has `pending=true`.
- **View tests** (SQL-level):
  - Visibility filter at the 5-minute boundary (rows older/newer than the threshold).
  - `COALESCE` returns root for pending case-A rows past the window.
  - `EXPLAIN ANALYZE` check on `user.thread` and `user.priority_unread` with 1k / 10k / 100k pending rows in `thread_priority`, asserting the planner uses the partial index `thread_priority_classify_pending_idx` for sweep-style queries and short-circuits the `priority_id IS NOT NULL` branch for the visibility filter on the hot path. Captured as a SQL test that fails if the plan regresses.
- **Trigger tests:** peer fan-out trigger writes pending rows; topic-change trigger marks settled rows (and ignores `user_moved=true` rows).
- **End-to-end** (integration): `POST /sync/capture` produces foreground author row (settled or pending depending on classifier behavior) + peer pending rows; manual queue drain advances them; visibility view returns the expected sequence; killing the consumer mid-flight and running the sweep recovers the rows.
- **Eval-suite parity:** after moving classifier files into `libs/classifier`, the existing `libs/eval/tests/ts-hybrid-llm*.test.ts` suite runs green unchanged (proves the move is a pure relocation).
- **Backwards-compat smoke:** Flutter Drift schema + `/sync/*` payload sample is identical before/after (proves the "no client changes" constraint).

---

## 12. Implementation surface

New:

- `libs/classifier/` package (extracted from `libs/eval/src/classifiers/` — pure orchestration, no I/O).
- `libs/classifier-runtime/` package (shared Worker adapters: `kv-cache.ts`, `kv-budget.ts`, `worker-gemini-client.ts`, `factory.ts`, `context.ts`, `canonical-input.ts`).
- `workers/classify/` consumer Worker (`wrangler.toml`, `src/index.ts`, `src/handler.ts`). No DLQ handler.
- `libs/db/schema/60-functions/mark_reclassify_candidates.sql`.
- `libs/db/schema/60-functions/mark_channel_default_candidates.sql`.
- `libs/db/schema/60-functions/classify_visibility_window.sql` (one-line interval helper for view tuning).
- `libs/db/schema/95-triggers/24-thread_priority_bump_parent.sql` (parent-seq trigger).
- `workers/api/src/app/admin/classify-sweep.ts` — `POST /admin/classify/sweep` endpoint, gated by the existing admin-auth middleware in `workers/api/src/app/admin/`.

Modified:

- `libs/db/schema/50-tables/27-thread_priority.sql` — nullable `priority_id`, new `classify_at`, partial index, CHECK constraint.
- `libs/db/schema/90-user-schema/*` — every view joining `thread_priority` gets the visibility filter + `COALESCE`.
- `libs/db/schema/95-triggers/22-thread_priority_peers.sql` — set-based pending-row insert.
- `libs/db/schema/95-triggers/23-thread_group_peers.sql` — same.
- `libs/db/schema/95-triggers/18-thread_topic_from_channel.sql` — single UPDATE marking pending.
- `libs/db/schema/90-user-schema/80-upsert_thread.sql` — peer + keyed-priority blocks write pending rows.
- `workers/api/src/state/classify-thread.ts` — TS classifier path returning `{ priorityId, pending }`; `enqueueJobs` chunking helper; `dispatchPendingForThread` helper.
- `workers/api/src/app/sync/capture.ts`, `sync/threads.ts`, `sync/priority-moves.ts`, `state/channel-router.ts`, `twist/tools/plot/thread-helpers.ts`, `twist/dev-activities.ts` — call the new path; persist the `pending` flag into the row insert; enqueue dispatch via `waitUntil` after the transaction commits.
- `workers/api/src/app/sync/{notify,schedules,thread-tags,priority-suggestions,authorize.test}.ts` and `workers/api/src/app/sync/capture.ts` (line 70 join) — handle nullable `thread_priority.priority_id` correctly per caller intent.
- `workers/api/wrangler.toml` — add KV binding `LLM_CACHE`, queue producer `QUEUE_CLASSIFY`, secret `GOOGLE_GENERATIVE_AI_API_KEY`. Declare `@plotday/classifier-runtime` workspace dep.
- `workers/cron/` (or equivalent) — add the hourly recovery sweep + pending-row gauge emission.

Follow-up migration:

- Drop `classify_thread_for_user`, `classify_thread_for_user_explain`, `match_priority_for_user`, `reclassify_user_threads`, `apply_channel_default`.

Out of scope (deliberately not in this spec):

- Flutter app changes — none required.
- Tuning of `ts:hybrid-llm` defaults beyond what's already in `DEFAULTS_LLM`.
- Any change to `/sync/*` payload shape.
- A per-user feature flag (replace outright; revert is rollback).
- A DLQ consumer (intentionally omitted; see §7 "Why no DLQ handler").

---

## 13. Risks

- **Cold KV cache on first deploy.** First hour sees ~0% hit rate → LLM cost spike. `DEFAULTS_LLM` budget caps bound the spike per user. Acceptable; alternative is a warmup script (out of scope).
- **KV eventual consistency across regions.** Cloudflare KV is eventually consistent across PoPs (seconds). Two near-simultaneous classify jobs for the same canonical input in different regions may each miss and each call the LLM. Cost impact is bounded; correctness is unaffected.
- **Sweep thrash for chronically-failing rows.** Without a DLQ handler, the sweep keeps re-enqueuing failing rows hourly until either the consumer succeeds or the row is manually finalized. Mitigations: (a) KV cache makes repeat attempts on identical inputs effectively free; (b) per-user daily budget caps bound LLM spend; (c) sweep-result alerting (§7) fires on `enqueued > 100` for ≥2h or `oldest_classify_at > 6h`, escalating to human intervention. Trade-off rationale in §7 "Why no DLQ handler" — we deliberately accept this in exchange for keeping correct classification recoverable after transient outages.
- **Silent failures.** A bug that swallows errors in the consumer would leave `classify_at` set indefinitely. The pending-row gauge + sweep-result alerting make this loud. Every catch block in the new code path must `captureException` per project convention; reviewer task.
- **View fallback window is a tradeoff.** 5 minutes means: short outages are invisible to users (no missed threads); brief root-then-correct moves happen only after the pipeline has been down ≥5 minutes. Lengthening the window improves the "no root bounce" property but worsens visibility latency during real outages. 5 min seems right; configurable via the `classify_visibility_window()` helper.
- **Visibility filter sargability.** The new `(tp.priority_id IS NOT NULL OR tp.classify_at < now() - interval '5 minutes')` predicate is non-trivial. EXPLAIN plans on `user.thread` and `user.priority_unread` at representative row counts (1k/10k/100k pending) must confirm the planner short-circuits the common case and uses the partial index for sweep-style scans. Captured as a regression test (§11).
- **Classifier dispatch must run post-commit.** §5 mandates `waitUntil` with a fresh `createDb` for `dispatchPendingForThread`. If a future refactor moves dispatch inside the transaction, `dispatchPendingForThread` must read from the open `trx` (not the outer `c.var.db`) and run **after** the trigger statements that create the pending rows. Reviewer task.
- **Trigger transactional atomicity loss.** Today peers see classified threads inside the originating transaction. After this, peers briefly see nothing, then the classified row. Net user impact is positive (they don't see the wrong filing first), but it's a semantic change other code shouldn't depend on. Audit complete; no callers rely on the old behavior.
- **`thread_unread` insertion remains in triggers** even though `thread_priority` row is hidden. The row is benign while invisible; surfaces correctly when visibility resolves. Alternative (move insert to consumer) was rejected as needless coordination.
- **Decommission order.** Drop the old SQL functions only after one full sweep cycle confirms no caller. Two-migration expand-contract for the function drops if anything still references them in production logs.

---

## 14. Rollout

1. Land `libs/classifier` extraction + `libs/classifier-runtime` package + eval-suite parity (no behavior change).
2. Land schema migration (nullable `priority_id`, `classify_at`, CHECK constraint, view updates, partial index, parent-seq-bump trigger) — backward compatible with the still-active SQL classifier.
3. Land `workers/classify` consumer Worker and KV/queue bindings. Deploy first; consumer sits idle because nothing is enqueueing yet. Verify consumer health, KV connectivity, and singleton classifier initialization via a synthetic test message.
4. Land trigger changes + API call-site changes + foreground TS classifier path. Producer starts enqueueing. The old SQL classifier function is no longer called but remains in the DB.
5. Monitor for two weeks: queue depth, KV hit rate, per-user budget consumption, pending-row gauge (`thread_priority WHERE classify_at IS NOT NULL`), view-fallback hit rate, foreground-failure rate (rows written with `pending=true`). Alert thresholds per §7 Error reporting.
6. After two weeks clean: follow-up migration drops the old SQL classifier functions.

Rollback at any step prior to step 6 is `git revert` of the relevant commits; the schema additions (nullable column, new column, CHECK, trigger, partial index, helper functions) are forward-compatible with the old SQL classifier, so the schema migration does not need to be rolled back.
