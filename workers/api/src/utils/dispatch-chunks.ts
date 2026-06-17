/**
 * Run `fn` over `items` in bounded chunks: each chunk of up to `chunkSize`
 * items runs concurrently, the next chunk does not start until the current one
 * settles, and `gapMs` is awaited between chunks. Returns the settled results in
 * input order (like `Promise.allSettled`) so callers can still count
 * successes/failures.
 *
 * Why this exists: a wide fan-out (one priority change → every twist the user
 * owns; one recovery sweep → up to 50 stale syncs) that fires every DO
 * notification at once schedules a burst of TwistSync/UserSync alarms inside the
 * same ~2s jitter window. Each alarm then opens a DB connection, and the spike
 * blows past Hyperdrive's pool ("Timed out while waiting for an open slot in the
 * pool"). Chunking caps how many notifications are dispatched together, and the
 * gap staggers the alarms' base scheduling times, keeping concurrent DB work
 * bounded. Fan-outs at or below `chunkSize` run in a single chunk with no added
 * delay, so the common small-fan-out case is unaffected.
 */
export async function dispatchInChunks<T, R>(
  items: readonly T[],
  fn: (item: T, index: number) => Promise<R>,
  { chunkSize, gapMs }: { chunkSize: number; gapMs: number }
): Promise<PromiseSettledResult<R>[]> {
  if (chunkSize < 1) {
    throw new Error(`dispatchInChunks: chunkSize must be >= 1, got ${chunkSize}`);
  }
  const results: PromiseSettledResult<R>[] = [];
  for (let start = 0; start < items.length; start += chunkSize) {
    const chunk = items.slice(start, start + chunkSize);
    const settled = await Promise.allSettled(
      chunk.map((item, i) => fn(item, start + i))
    );
    results.push(...settled);
    const hasMore = start + chunkSize < items.length;
    if (hasMore && gapMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, gapMs));
    }
  }
  return results;
}

/**
 * Shared chunk/gap for DO-notification fan-out. `chunkSize` is small enough that
 * a single change for a normal user (a handful of twists) dispatches in one
 * chunk with no delay, while a wide fan-out or a 50-item recovery sweep is
 * spread across several chunks. Raise alongside the Hyperdrive connection limit.
 */
export const FAN_OUT_DISPATCH = { chunkSize: 10, gapMs: 250 } as const;
