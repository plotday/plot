import {
  classifierContextFromDb,
  getProductionClassifier,
} from "@plotday/classifier-runtime";
import type { Candidate, ClassifierBatchCache } from "@plotday/classifier";

import { retryOnTxnConflict } from "@plotday/worker-util";

import { sql, type ClassifyDb } from "./db";

export type ClassifyJob = { userId: string; threadId: string };

export type ClassifyEnv = {
  readonly LLM_CACHE: KVNamespace;
  readonly GOOGLE_GENERATIVE_AI_API_KEY: string;
};

/**
 * Handle a single classify-thread queue message.
 *
 * Pre-flight check via the partial index on classify_at — skip rows that
 * have already been settled (classify_at cleared) or stickied
 * (user_moved). Then run the classifier over a Kysely-backed context
 * (live `public.*` schema, no sandbox).
 *
 * The UPDATE is guarded by the row's prior priority_id snapshot so
 * concurrent user moves don't get clobbered. The parent-seq trigger on
 * thread_priority bumps thread.updated_at whenever priority_id changes;
 * the "same result" branch (just clearing classify_at) intentionally
 * does NOT bump so a no-op classification doesn't trigger client
 * re-sync.
 */
export type ClassifyOutcome = {
  status: "skipped" | "settled" | "same" | "moved";
  /** Cascade stage that produced the result (undefined when skipped pre-classify). */
  stage?: string;
  llmCalls?: number;
  cacheHits?: number;
  /** True when an LLM stage was skipped for lack of budget (see classifier). */
  budgetExhausted?: boolean;
};

export async function handleClassifyJob(
  job: ClassifyJob,
  env: ClassifyEnv,
  db: ClassifyDb,
  onError?: (err: unknown) => void,
  batchCache?: ClassifierBatchCache
): Promise<ClassifyOutcome> {
  const row = await db
    .selectFrom("thread_priority")
    .select(["priority_id", "user_moved", "classify_at"])
    .where("user_id", "=", job.userId)
    .where("thread_id", "=", job.threadId)
    .executeTakeFirst();

  if (!row) return { status: "skipped" };
  if (row.classify_at == null) return { status: "skipped" };
  if (row.user_moved) {
    // The placement is sticky (the user's explicit choice) so we never re-file
    // this row — but classify_at is still set, because a reclassify/channel/
    // topic marker raced the user's move (the marker guards on user_moved =
    // FALSE, but the move can land between mark and settle). Leaving classify_at
    // set strands the row: the hourly sweep re-enqueues it every hour forever
    // and this same skip fires again, draining nothing (prod: 1428 such rows,
    // oldest a month old — PostHog 019ed53e backlog). Clear it with a quiet,
    // guarded keyed write so the row finally settles. The user_moved = TRUE
    // guard avoids clobbering a row whose stickiness changed under us; the
    // classify_at-only update is quiet — no seq / user_sync bump (see
    // thread_priority_seq_and_updated_at / sync_user_for_thread_priority_update).
    await db
      .updateTable("thread_priority")
      .set({ classify_at: null })
      .where("user_id", "=", job.userId)
      .where("thread_id", "=", job.threadId)
      .where("user_moved", "=", true)
      .execute();
    return { status: "skipped" };
  }

  const snapshot = row.priority_id; // null = case A (initial classify)

  // Build a Candidate matching the eval-side shape. We let the cascade
  // pull thread/contacts/groups/embedding from the DB via rawQuery —
  // pass a minimal Candidate here.
  const candidate: Candidate = {
    threadId: job.threadId,
    title: "",
    topic: null,
    contacts: [],
    groups: [],
    embedding: null,
    author: null,
    facets: null,
    authorContactId: null,
    connectionId: null,
  };

  // Hydrate candidate from the thread row so cascade stages have it
  // without each one re-querying. The cascade still uses rawQuery for
  // other lookups (user_moved training set, priorities, etc.).
  const threadRow = await sql<{
    title: string | null;
    topic: string | null;
    contacts: string[] | null;
    groups: string[] | null;
    embedding: string | null;
    created_by: string | null;
    facets: Record<string, string> | null;
    author_id: string | null;
    twist_id: string | null;
  }>`SELECT t.title, t.topic, t.contacts, t.groups,
            CASE WHEN t.embedding IS NULL THEN NULL ELSE t.embedding::text END AS embedding,
            t.created_by, t.facets, t.author_id, t.twist_id
       FROM public.thread t
      WHERE t.id = ${job.threadId}::uuid`.execute(db);
  const r = threadRow.rows[0];
  if (r) {
    candidate.title = r.title ?? "";
    candidate.topic = r.topic;
    candidate.contacts = r.contacts ?? [];
    candidate.groups = r.groups ?? [];
    candidate.embedding = parseEmbedding(r.embedding);
    candidate.author = r.created_by;
    candidate.facets = r.facets;
    candidate.authorContactId = r.author_id;
    candidate.connectionId = r.twist_id != null ? r.created_by : null;
  }

  const classifier = getProductionClassifier(env);
  const ctx = classifierContextFromDb(db, job.userId, batchCache);
  const result = await classifier.classify(ctx, candidate);

  // Telemetry surfaced to PostHog (see workers/classify/src/index.ts) so a
  // shift in stage mix or a spike in budgetExhausted is observable.
  const telemetry: Omit<ClassifyOutcome, "status"> = {
    stage: result.stage,
    llmCalls: result.llmCalls,
    cacheHits: result.cacheHits,
    budgetExhausted: result.budgetExhausted,
  };

  // Append-only decision log (spec B2.2): record the applied result
  // verbatim whenever this job's outcome is applied (settled/moved/same).
  // result.priorityId may be null (stage 'none') even though the worker
  // applies a snapshot/root fallback — never substitute it in. Runs on the
  // pool handle after the settle transaction, so a failure can't poison
  // anything; it must never fail the filing.
  //
  // Column list must stay in sync with logClassificationDecision in
  // workers/api/src/state/classify-thread.ts (the workers share no code).
  const logDecision = async () => {
    try {
      await sql`
        INSERT INTO public.classification_decision
          (thread_id, user_id, priority_id, stage, scores, classifier,
           llm_calls, cache_hits, budget_exhausted, duration_ms)
        VALUES
          (${job.threadId}::uuid, ${job.userId}::uuid,
           ${result.priorityId}::uuid, ${result.stage},
           ${JSON.stringify(result.scores ?? {})}::jsonb, ${classifier.name},
           ${result.llmCalls ?? 0}, ${result.cacheHits ?? 0},
           ${result.budgetExhausted ?? false}, ${result.durationMs ?? null})
      `.execute(db);
    } catch (err) {
      onError?.(err);
    }
  };

  // If the classifier returned null, case A falls back to root; B/D
  // stays at the snapshot so we never bounce settled rows through root.
  let target = result.priorityId;
  if (target == null) {
    if (snapshot != null) {
      target = snapshot;
    } else {
      const rootRow = await sql<{ id: string }>`
        SELECT id FROM public.priority
         WHERE user_id = ${job.userId}::uuid
           AND nlevel(path) = 1
           AND archived_at IS NULL
         ORDER BY created_at ASC
         LIMIT 1`.execute(db);
      target = rootRow.rows[0]?.id ?? null;
      if (target == null) return { status: "skipped", ...telemetry };
    }
  }

  if (snapshot == null) {
    // Case A: write the classified priority, clear classify_at.
    // Guard with priority_id IS NULL so a concurrent user move wins.
    const updated = await settlePriority(db, job, (trx) =>
      trx
        .updateTable("thread_priority")
        .set({ priority_id: target, classify_at: null })
        .where("user_id", "=", job.userId)
        .where("thread_id", "=", job.threadId)
        .where("priority_id", "is", null)
        .where("user_moved", "=", false)
        .executeTakeFirst()
    );
    const applied = updated.numUpdatedRows > 0n;
    if (applied) await logDecision();
    return { status: applied ? "settled" : "skipped", ...telemetry };
  } else if (target !== snapshot) {
    // Cases B-D with a different classifier result. Guard with the
    // snapshot so concurrent moves win.
    const updated = await settlePriority(db, job, (trx) =>
      trx
        .updateTable("thread_priority")
        .set({ priority_id: target, classify_at: null })
        .where("user_id", "=", job.userId)
        .where("thread_id", "=", job.threadId)
        .where("priority_id", "=", snapshot)
        .where("user_moved", "=", false)
        .executeTakeFirst()
    );
    const applied = updated.numUpdatedRows > 0n;
    if (applied) await logDecision();
    return { status: applied ? "moved" : "skipped", ...telemetry };
  } else {
    // Same result — only clear classify_at. Does NOT bump
    // thread.updated_at (the parent-seq trigger excludes this branch).
    await db
      .updateTable("thread_priority")
      .set({ classify_at: null })
      .where("user_id", "=", job.userId)
      .where("thread_id", "=", job.threadId)
      .execute();
    await logDecision();
    return { status: "same", ...telemetry };
  }
}

/**
 * Run a priority_id-changing thread_priority update with deadlock-safe lock
 * ordering. The update fires the thread_priority_bump_parent trigger, which
 * UPDATEs the parent thread row — so a bare statement acquires locks
 * thread_priority → thread, the OPPOSITE of upsert_thread (connector saves
 * and client sync), which locks thread first and then writes thread_priority
 * via its filing triggers. With both writers racing on the same thread right
 * after creation (every connector thread immediately enqueues a classify
 * job), that opposite order deadlocks. Locking the parent thread row first
 * makes every writer acquire thread → thread_priority.
 *
 * retryOnTxnConflict is kept as defense for cycles this ordering doesn't
 * cover; the update is guarded/idempotent so re-running is safe.
 */
async function settlePriority<T>(
  db: ClassifyDb,
  job: ClassifyJob,
  update: (trx: ClassifyDb) => Promise<T>
): Promise<T> {
  return retryOnTxnConflict(() =>
    db.transaction().execute(async (trx) => {
      await sql`SELECT 1 FROM public.thread WHERE id = ${job.threadId}::uuid FOR NO KEY UPDATE`.execute(
        trx
      );
      return update(trx);
    })
  );
}

/**
 * Give-up fallback for a thread that repeatedly fails to classify — a slow
 * scoring query that trips the 30s statement_timeout (57014), or sustained
 * user_sync row-lock contention. Files the thread at the user's root focus if
 * it is still unfiled and clears classify_at so the hourly sweep stops
 * re-enqueuing it. That re-enqueue (classify_at never clearing) is what turns a
 * single slow/contended thread into an unbounded retry storm, so parking is the
 * circuit breaker.
 *
 * Deliberately scoring-free and cheap (one keyed UPDATE) so it still succeeds
 * while the scoring query itself is too slow to run. COALESCE never overwrites
 * an existing priority_id, and the user_moved = FALSE guard preserves an
 * explicit user filing. Uses the same parent-thread lock ordering as
 * settlePriority to stay deadlock-safe against a concurrent upsert_thread.
 * Returns whether a row was parked.
 */
export async function parkUnclassifiable(
  db: ClassifyDb,
  job: ClassifyJob
): Promise<boolean> {
  const rootRow = await sql<{ id: string }>`
    SELECT id FROM public.priority
     WHERE user_id = ${job.userId}::uuid
       AND nlevel(path) = 1
       AND archived_at IS NULL
     ORDER BY created_at ASC
     LIMIT 1`.execute(db);
  const root = rootRow.rows[0]?.id ?? null;
  const updated = await settlePriority(db, job, (trx) =>
    trx
      .updateTable("thread_priority")
      .set({
        priority_id: sql<string>`COALESCE("thread_priority"."priority_id", ${root}::uuid)`,
        classify_at: null,
      })
      .where("user_id", "=", job.userId)
      .where("thread_id", "=", job.threadId)
      .where("user_moved", "=", false)
      .executeTakeFirst()
  );
  return updated.numUpdatedRows > 0n;
}

function parseEmbedding(text: string | null): number[] | null {
  if (text == null) return null;
  const inner = text.trim();
  if (!inner.startsWith("[") || !inner.endsWith("]")) return null;
  const stripped = inner.slice(1, -1);
  if (stripped === "") return [];
  return stripped.split(",").map((s) => Number(s));
}
