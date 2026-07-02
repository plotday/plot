import { type Kysely } from "kysely";
import { PostHog } from "posthog-node";

import {
  classifierContextFromDb,
  getProductionClassifier,
  type ClassifierEnv,
} from "@plotday/classifier-runtime";
import type { Candidate } from "@plotday/classifier";
import { exceptionFingerprintBeforeSend } from "@plotday/worker-util";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import { sql } from "../db";
import { isAiEnabled } from "../utils/ai-limits";

export type ClassifyArgs = {
  userId: string;
  threadId?: string;
  embedding?: string | null;
  topic?: string | null;
  contacts?: string[] | null;
  groups?: string[] | null;
  /** Pre-insert callers: thread.facets when known. */
  facets?: Record<string, string> | null;
  /** Pre-insert callers: originating twist_instance id when known. */
  connectionId?: string | null;
};

export type ClassifyResult = {
  /** The user's resolved priority filing. Always non-null. */
  priorityId: string;
  /**
   * True when the classifier threw (transient failure). The caller MUST
   * persist this thread_priority row with classify_at = now() so the
   * consumer Worker (or the hourly sweep) re-attempts later.
   */
  pending: boolean;
  /**
   * Present only for pre-insert callers (no threadId yet): the decision
   * entry to log via logClassificationDecision once the thread row exists.
   * Callers that passed a threadId never see this — the decision was
   * already logged here.
   */
  pendingLog?: PendingDecision;
};

export type PendingDecision = {
  userId: string;
  priorityId: string | null;
  stage: string;
  scores: Record<string, unknown>;
  classifier: string;
  llmCalls?: number;
  cacheHits?: number;
  budgetExhausted?: boolean;
  durationMs?: number | null;
};

export type ClassificationDecisionLog = PendingDecision & { threadId: string };

/**
 * Append a classification_decision row (spec B2). Best-effort: a logging
 * failure must never fail or delay a filing — failures are captured to
 * PostHog and swallowed.
 */
export async function logClassificationDecision(
  db: Kysely<DB>,
  env: Bindings,
  entry: ClassificationDecisionLog
): Promise<void> {
  // On a shared transaction a failed INSERT would abort the whole txn
  // (25P02) — the catch below can't clear that server-side state, and the
  // caller's COMMIT would silently become ROLLBACK, discarding the filing
  // this helper must never disturb. A savepoint scopes the failure to the
  // log attempt alone. Pool handles autocommit per statement, so the plain
  // path needs no savepoint.
  const inTransaction = db.isTransaction;
  try {
    if (inTransaction)
      await sql`SAVEPOINT classification_decision_log`.execute(db);
    await sql`
      INSERT INTO public.classification_decision
        (thread_id, user_id, priority_id, stage, scores, classifier,
         llm_calls, cache_hits, budget_exhausted, duration_ms)
      VALUES
        (${entry.threadId}::uuid, ${entry.userId}::uuid,
         ${entry.priorityId}::uuid, ${entry.stage},
         ${JSON.stringify(entry.scores)}::jsonb, ${entry.classifier},
         ${entry.llmCalls ?? 0}, ${entry.cacheHits ?? 0},
         ${entry.budgetExhausted ?? false}, ${entry.durationMs ?? null})
    `.execute(db);
    if (inTransaction)
      await sql`RELEASE SAVEPOINT classification_decision_log`.execute(db);
  } catch (err) {
    if (inTransaction) {
      try {
        await sql`ROLLBACK TO SAVEPOINT classification_decision_log`.execute(db);
      } catch {
        // If even the rollback-to fails the outer txn is already doomed;
        // nothing more we can do here.
      }
    }
    capture(env, err, entry.userId, entry.threadId);
  }
}

export type ClassifyExplanation = {
  priorityId: string | null;
  stage: string;
  scores: Record<string, unknown>;
};

export type ClassifyJob = { userId: string; threadId: string };

/** Cloudflare Queues caps sendBatch at 100 messages. */
const QUEUE_BATCH_SIZE = 100;

/** Bindings that the classifier touches (a subset of `Bindings`). */
type ClassifyEnvBindings = ClassifierEnv & {
  readonly QUEUE_CLASSIFY: Queue<ClassifyJob>;
};

/**
 * Foreground classifier: returns the user's resolved priority filing.
 * On classifier failure (LLM timeout, network blip), files at root with
 * `pending = true` so the call site can durably mark the row for the
 * consumer Worker to retry.
 */
export async function classifyThreadForUser(
  db: Kysely<DB>,
  env: Bindings,
  args: ClassifyArgs
): Promise<ClassifyResult> {
  try {
    const classifier = getProductionClassifier(envWithClassifierBindings(env));
    // Honor the user's built-in-AI opt-out: with AI off the cascade still runs,
    // but every LLM stage is skipped (ctx.aiDisabled), so the thread is filed
    // by the deterministic stages alone — no model call for classification.
    const aiDisabled = !(await isAiEnabled(db, args.userId));
    // Per-call memo: one classify runs several cascade stages (scoring,
    // cold-start, tie-breaker, topic-LLM) that each re-read the same
    // user-scoped facts (focuses, linked contacts, affinity); cache them once.
    const ctx = {
      ...classifierContextFromDb(db, args.userId, new Map()),
      aiDisabled,
    };
    const candidate = await buildCandidate(db, args);
    const result = await classifier.classify(ctx, candidate);
    // Log the decision verbatim — for stage 'none', priority_id stays NULL
    // (the root filing below is a caller-side fallback, not the decision).
    const entry: PendingDecision = {
      userId: args.userId,
      priorityId: result.priorityId,
      stage: result.stage,
      scores: result.scores ?? {},
      classifier: classifier.name,
      llmCalls: result.llmCalls,
      cacheHits: result.cacheHits,
      budgetExhausted: result.budgetExhausted,
      durationMs: result.durationMs,
    };
    const priorityId =
      result.priorityId ?? (await rootPriorityId(db, args.userId));
    if (args.threadId) {
      await logClassificationDecision(db, env, {
        ...entry,
        threadId: args.threadId,
      });
      return { priorityId, pending: false };
    }
    return { priorityId, pending: false, pendingLog: entry };
  } catch (err) {
    capture(env, err, args.userId, args.threadId);
    // Transient failure — file at root for instant author visibility,
    // mark pending so the consumer eventually re-runs.
    return { priorityId: await rootPriorityId(db, args.userId), pending: true };
  }
}

/**
 * Verbose variant used by admin/debug routes. Production callers use
 * classifyThreadForUser instead.
 */
export async function classifyThreadForUserExplain(
  db: Kysely<DB>,
  env: Bindings,
  args: ClassifyArgs
): Promise<ClassifyExplanation> {
  const classifier = getProductionClassifier(envWithClassifierBindings(env));
  const ctx = classifierContextFromDb(db, args.userId, new Map());
  const candidate = await buildCandidate(db, args);
  const result = await classifier.classify(ctx, candidate);
  return {
    priorityId: result.priorityId,
    stage: result.stage,
    scores: result.scores ?? {},
  };
}

/**
 * Enqueue ClassifyJob messages, batched by the queue's 100-message cap.
 * Used by the foreground dispatch (per-thread peers) and the hourly
 * sweep (long-tail recovery). Cluster of related call sites must all go
 * through this helper to keep batch sizes correct.
 */
export async function enqueueJobs(
  env: ClassifyEnvBindings,
  jobs: ClassifyJob[]
): Promise<void> {
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

/**
 * Find every pending thread_priority row for the given thread and
 * enqueue classify jobs. Must be called from `c.executionCtx.waitUntil`
 * AFTER the transaction commits — pending rows aren't visible inside
 * the writing transaction. Opens a fresh DB connection (the
 * request-scoped one is destroyed by the time waitUntil runs).
 */
export async function dispatchPendingForThread(
  db: Kysely<DB>,
  env: ClassifyEnvBindings,
  threadId: string
): Promise<void> {
  // sql template (not Kysely's typed query builder) because classify_at
  // is new — kysely-codegen db-types haven't been regenerated yet.
  const rows = await sql<{ user_id: string }>`
    SELECT user_id FROM public.thread_priority
     WHERE thread_id = ${threadId}::uuid
       AND classify_at IS NOT NULL`.execute(db);
  await enqueueJobs(
    env,
    rows.rows.map((r) => ({ userId: r.user_id, threadId }))
  );
}

/**
 * Sweep entry point — re-enqueue every pending row older than 1 hour.
 * Bounded at 1000 rows per call so a backlog drains over multiple
 * sweep ticks without one call timing out.
 */
export async function runSweep(
  db: Kysely<DB>,
  env: ClassifyEnvBindings,
  limit = 1000
): Promise<{ enqueued: number; oldestClassifyAt: Date | null }> {
  const stuck = await sql<{
    user_id: string;
    thread_id: string;
    classify_at: Date;
  }>`
    SELECT user_id, thread_id, classify_at
      FROM public.thread_priority
     WHERE classify_at IS NOT NULL
       AND classify_at < now() - interval '1 hour'
     ORDER BY classify_at ASC
     LIMIT ${limit}`.execute(db);
  const oldestClassifyAt =
    stuck.rows.length > 0 ? (stuck.rows[0]!.classify_at ?? null) : null;
  await enqueueJobs(
    env,
    stuck.rows.map((r) => ({ userId: r.user_id, threadId: r.thread_id }))
  );
  return { enqueued: stuck.rows.length, oldestClassifyAt };
}

async function buildCandidate(
  db: Kysely<DB>,
  args: ClassifyArgs
): Promise<Candidate> {
  // When we have a threadId, hydrate from the live row so the candidate
  // matches what the cascade's stages will see. When we don't (pre-insert
  // "match priority" callers), use only what the caller passed.
  let title = "";
  let topic = args.topic ?? null;
  let contacts = args.contacts ?? [];
  let groups = args.groups ?? [];
  let embedding = parseEmbedding(args.embedding ?? null);
  let author: string | null = null;
  let facets: Record<string, string> | null = args.facets ?? null;
  let authorContactId: string | null = null;
  let connectionId: string | null = args.connectionId ?? null;

  if (args.threadId) {
    const res = await sql<{
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
        WHERE t.id = ${args.threadId}::uuid`.execute(db);
    const r = res.rows[0];
    if (r) {
      title = r.title ?? "";
      topic = topic ?? r.topic;
      contacts = (args.contacts ?? r.contacts ?? []) as string[];
      groups = (args.groups ?? r.groups ?? []) as string[];
      embedding = embedding ?? parseEmbedding(r.embedding);
      author = r.created_by;
      facets = facets ?? r.facets;
      authorContactId = r.author_id;
      connectionId = connectionId ?? (r.twist_id != null ? r.created_by : null);
    }
  }

  return {
    threadId: args.threadId ?? "",
    title,
    topic,
    contacts,
    groups,
    embedding,
    author,
    facets,
    authorContactId,
    connectionId,
  };
}

async function rootPriorityId(
  db: Kysely<DB>,
  userId: string
): Promise<string> {
  // No-specific-focus fallback: the Inbox focus of the user's oldest
  // non-archived role (mirrors user.fallback_inbox_id). Replaces the old
  // single-root nlevel(path)=1 lookup now that the flat model groups focuses
  // under roles, each with its own Inbox.
  const row = await db
    .selectFrom("role")
    .innerJoin("priority", (j) =>
      j
        .onRef("priority.role_id", "=", "role.id")
        .on("priority.is_inbox", "=", true)
        .on("priority.archived_at", "is", null)
    )
    .select("priority.id as id")
    .where("role.user_id", "=", userId)
    .where("role.archived_at", "is", null)
    .orderBy("role.created_at", "asc")
    .limit(1)
    .executeTakeFirst();
  if (!row?.id) {
    throw new Error(
      `classify-thread: user ${userId} has no role inbox — refusing to fabricate one. Run activate_invited_user first.`
    );
  }
  return row.id;
}

function parseEmbedding(text: string | null): number[] | null {
  if (text == null) return null;
  const inner = text.trim();
  if (!inner.startsWith("[") || !inner.endsWith("]")) return null;
  const stripped = inner.slice(1, -1);
  if (stripped === "") return [];
  return stripped.split(",").map((s) => Number(s));
}

function envWithClassifierBindings(env: Bindings): ClassifierEnv {
  return {
    LLM_CACHE: env.LLM_CACHE,
    GOOGLE_GENERATIVE_AI_API_KEY: env.GOOGLE_GENERATIVE_AI_API_KEY,
  };
}

function capture(
  env: Bindings,
  err: unknown,
  userId: string,
  threadId: string | undefined
): void {
  try {
    const posthog = new PostHog(env.POSTHOG_API_KEY, {
      host: env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
      before_send: exceptionFingerprintBeforeSend,
    });
    posthog.captureException(err as Error, userId, { threadId });
    void posthog.shutdown();
  } catch {
    // Telemetry must never block classification.
  }
}
