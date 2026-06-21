import {
  fetchTrainingRows,
  TRAINING_READ_KEY,
  userReadCacheKey,
  type ClassifierBatchCache,
  type RawQuery,
  type TrainingRow,
} from "@plotday/classifier";

import type { ClassifyJob } from "./handler";

/**
 * Cross-batch cache of the `user_moved` training set, layered over the classify
 * queue consumer.
 *
 * scoringStage memoizes the training fetch per (user, batch) via cachedUserRead,
 * but the hourly sweep enqueues hundreds of ONE user's pending threads in
 * CONSECUTIVE batches, so that per-batch memo still re-issues the heavy
 * thread_priority⋈thread fetch (embeddings serialized as text) for every batch.
 * Under saturation that fetch tripped the 30s statement_timeout (PostHog
 * 019ed53e). The training set only changes on an explicit user move (rare), so
 * a short-TTL module-global cache lets a whole sweep share ONE fetch instead of
 * one per batch — cutting both the timeout opportunities and the DB load (the
 * saturated resource) by roughly the batch count.
 *
 * Cosine (`sem`) is still computed in the worker from these embeddings — V8 has
 * spare CPU; pushing it into the saturated DB measured ~7x slower. We only cache
 * the fetch, not the scoring.
 *
 * The cache is a perf optimization, not a source of truth: a miss (cold isolate,
 * expired TTL, evicted) simply refetches, and a rejected fetch is never cached.
 * Staleness is bounded by the TTL and is harmless — classification is
 * best-effort and re-swept hourly.
 */

/** How long a cached training set is reused before refetching. */
export const TRAINING_CACHE_TTL_MS = 60_000;

/** Cap on distinct users held at once (bounds isolate memory). */
const MAX_USERS = 4;

type Entry = { expires: number; rows: Promise<TrainingRow[]> };

const cache = new Map<string, Entry>();

/** Test-only: clear the module-global cache between cases. */
export function resetTrainingCacheForTests(): void {
  cache.clear();
}

function getTraining(
  rawQuery: RawQuery,
  userId: string,
  now: number
): Promise<TrainingRow[]> {
  const hit = cache.get(userId);
  if (hit && hit.expires > now) return hit.rows;

  const rows = fetchTrainingRows(rawQuery, userId);
  cache.set(userId, { expires: now + TRAINING_CACHE_TTL_MS, rows });

  // Never persist a failed fetch: drop it so the next batch retries instead of
  // serving a rejected promise for the whole TTL window. The handler attached
  // here also marks the rejection handled, so an un-awaited prime (e.g. a
  // mocked consumer) can't surface as an unhandled rejection.
  rows.catch(() => {
    if (cache.get(userId)?.rows === rows) cache.delete(userId);
  });

  // Bound memory: evict the oldest entries beyond the cap (Map preserves
  // insertion order; the just-set user is newest, so it's never the victim).
  while (cache.size > MAX_USERS) {
    const oldest = cache.keys().next().value;
    if (oldest === undefined) break;
    cache.delete(oldest);
  }

  return rows;
}

/**
 * Seed the per-batch `batchCache` with each user's (cross-batch-cached) training
 * set under the exact slot scoringStage reads (`scoring:training`), so a sweep's
 * consecutive batches share one fetch. Synchronous: it stores the in-flight
 * promise; scoringStage awaits it (and defers on rejection, unchanged). Best
 * effort — a fetch failure just makes that user's threads defer this batch.
 */
export function primeTrainingCache(
  rawQuery: RawQuery,
  batchCache: ClassifierBatchCache,
  jobs: ClassifyJob[],
  now: number
): void {
  const users = new Set(jobs.map((j) => j.userId));
  for (const userId of users) {
    batchCache.set(
      userReadCacheKey(userId, TRAINING_READ_KEY),
      getTraining(rawQuery, userId, now)
    );
  }
}
