import type { ClassifierContext } from "./types";

/**
 * The composite key under which {@link cachedUserRead} stores a read: the user
 * id scopes every batch-stable read so two users in one batch never collide.
 * Exported so an out-of-band primer (the classify worker's cross-batch training
 * cache) can seed `batchCache` under the exact key scoringStage will look up.
 */
export function userReadCacheKey(userId: string, readKey: string): string {
  return `${userId}:${readKey}`;
}

/**
 * Memoize a user-scoped, batch-stable read for the life of a classify batch.
 *
 * The cascade re-derives several user-scoped facts on every thread it
 * classifies — the user_moved training set, the negative set, the user's
 * focuses/role hierarchies, linked contacts, account→hierarchy affinity. None
 * of those change while a single batch is processed (auto-classification never
 * writes the training set; only an explicit user move does, and that arrives as
 * its own later job). The hourly sweep enqueues hundreds of ONE user's pending
 * threads contiguously, so a batch is dominated by a single user — re-issuing
 * each of these reads per thread is what saturated the DB under load (PostHog
 * 019ed53e). With a `ctx.batchCache` present we run the loader once per
 * `${userId}:${key}` and reuse it for every later candidate in the batch (and
 * across cascade stages within one classify, which each call these reads).
 *
 * The settled promise is cached, INCLUDING rejections: if the first thread's
 * read trips the statement_timeout under saturation, the rest of that user's
 * batch fails fast and defers to the sweep rather than each re-issuing the same
 * 30s-timing-out query and adding more load. Classification is best-effort and
 * re-swept hourly, so a rare transient read failure deferring the batch's
 * remaining same-user threads is acceptable.
 *
 * With no `batchCache` (eval harness, unit tests) the loader runs every call —
 * behaviour is identical, just not deduplicated.
 */
export function cachedUserRead<T>(
  ctx: ClassifierContext,
  key: string,
  loader: () => Promise<T>
): Promise<T> {
  const cache = ctx.batchCache;
  if (!cache) return loader();
  const fullKey = userReadCacheKey(ctx.userId, key);
  const existing = cache.get(fullKey) as Promise<T> | undefined;
  if (existing) return existing;
  const pending = loader();
  cache.set(fullKey, pending);
  return pending;
}
