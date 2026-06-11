import { type Kysely } from "kysely";
import { PostHog } from "posthog-node";

import {
  classifierContextFromDb,
  getProductionClassifier,
  type ClassifierEnv,
} from "@plotday/classifier-runtime";
import type { Candidate } from "@plotday/classifier";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import { sql } from "../db";

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
};

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
    const ctx = classifierContextFromDb(db, args.userId);
    const candidate = await buildCandidate(db, args);
    const result = await classifier.classify(ctx, candidate);
    if (result.priorityId) {
      return { priorityId: result.priorityId, pending: false };
    }
    // Normal "no match" — file at root, settled. No async retry needed.
    return { priorityId: await rootPriorityId(db, args.userId), pending: false };
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
  const ctx = classifierContextFromDb(db, args.userId);
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
      facets = facets ?? r.facets ?? null;
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
  // Use the typed query builder rather than `sql\`...\`.execute(db)` so the
  // call site works with the dbMock helpers in
  // workers/api/src/twist/tools/__tests__/plot.test.ts. Mirrors the shape
  // of Plot.getRootPriorityId so a single mock setup covers both call
  // sites. nlevel(path)=1 is the schema invariant for a root priority;
  // ORDER BY nlevel + created_at also matches Plot.getRootPriorityId so
  // both helpers resolve to the same row on multi-root edge cases.
  const row = await db
    .selectFrom("priority")
    .select("id")
    .where("user_id", "=", userId)
    .where("archived_at", "is", null)
    .orderBy(sql`nlevel(path)`, "asc")
    .orderBy("created_at", "asc")
    .limit(1)
    .executeTakeFirst();
  if (!row?.id) {
    throw new Error(
      `classify-thread: user ${userId} has no root priority — refusing to fabricate one. Run activate_invited_user first.`
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
    });
    posthog.captureException(err as Error, userId, { threadId });
    void posthog.shutdown();
  } catch {
    // Telemetry must never block classification.
  }
}
