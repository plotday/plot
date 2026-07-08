/**
 * Run `fn` over `items` with at most `limit` concurrent executions.
 * Results keep the input order. `fn` must handle its own errors — a
 * rejection from `fn` rejects the whole pool (the eval runner catches
 * per-spec errors inside `fn`).
 */
export async function runPool<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R>
): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  const workers = Array.from(
    { length: Math.max(1, Math.min(limit, items.length)) },
    async () => {
      for (;;) {
        const i = next++;
        if (i >= items.length) return;
        results[i] = await fn(items[i], i);
      }
    }
  );
  await Promise.all(workers);
  return results;
}
