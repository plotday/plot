/**
 * The user_moved training-set fetch shared by the scoring stage and the
 * classify queue consumer.
 *
 * The scoring stage scores a candidate against the user's explicitly-moved
 * threads. The cosine (`sem`) signal is computed in the WORKER from each
 * training thread's halfvec embedding — V8 has spare CPU and does it in
 * microseconds, whereas the database is the saturated component (computing
 * cosine there for the whole training set, measured, is ~7x slower). So we ship
 * the embeddings to the worker; the only avoidable cost is HOW OFTEN that fetch
 * runs. The hourly sweep enqueues hundreds of ONE user's pending threads in
 * consecutive batches, and the per-batch `cachedUserRead` memo still re-fetches
 * for every batch — under saturation that fetch tripped the 30s statement_timeout
 * (PostHog 019ed53e). The classify worker layers a short-TTL cross-batch cache
 * over this function so the fetch runs ~once per sweep instead of once per batch.
 *
 * Exported so the worker's cross-batch cache and scoringStage run the IDENTICAL
 * query and row shape — the worker seeds `cachedUserRead`'s `scoring:training`
 * slot, so the two MUST agree.
 */

/** Function shape of `ClassifierContext.rawQuery` / a worker DB adapter. */
export type RawQuery = (
  text: string,
  values?: unknown[]
) => Promise<{ rows: unknown[] }>;

/** `cachedUserRead` slot the training set is memoized under. */
export const TRAINING_READ_KEY = "scoring:training";

export type TrainingRow = {
  priority_id: string;
  thread_id: string;
  title: string | null;
  topic: string | null;
  created_by: string | null;
  conn_id: string | null;
  contacts: string[] | null;
  groups: string[] | null;
  /** halfvec serialized to text; null when the thread has no embedding. */
  embedding: string | null;
};

/**
 * Fetch the user's `user_moved` training threads with the signals the scoring
 * stage needs (embedding included, as text). Pure in `rawQuery` — no caching
 * here; callers layer their own memo (per-batch `cachedUserRead`, the worker's
 * cross-batch TTL cache).
 */
export async function fetchTrainingRows(
  rawQuery: RawQuery,
  userId: string
): Promise<TrainingRow[]> {
  const res = await rawQuery(
    `SELECT tp.priority_id,
            tp.thread_id,
            mt.title,
            mt.topic,
            mt.created_by,
            CASE WHEN mt.twist_id IS NOT NULL THEN mt.created_by ELSE NULL END AS conn_id,
            mt.contacts,
            mt.groups,
            CASE WHEN mt.embedding IS NULL THEN NULL ELSE mt.embedding::text END AS embedding
       FROM public.thread_priority tp
       JOIN public.thread mt ON mt.id = tp.thread_id
      WHERE tp.user_id = $1::uuid
        AND tp.user_moved = TRUE
        AND mt.archived_at IS NULL`,
    [userId]
  );
  return res.rows as TrainingRow[];
}
