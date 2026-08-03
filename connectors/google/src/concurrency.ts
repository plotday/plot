/**
 * Maps `items` with at most `limit` mappers in flight, resolving to results in
 * input order. A mapper rejection rejects the whole call — callers that want
 * per-item failure semantics catch inside `fn`.
 *
 * Shared by the mail and calendar product modules. It lives here rather than in
 * either module so neither has to import from the other.
 */
export async function mapWithConcurrency<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R>
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  const workers = Array.from(
    { length: Math.min(limit, items.length) },
    async () => {
      while (next < items.length) {
        const index = next++;
        results[index] = await fn(items[index], index);
      }
    }
  );
  await Promise.all(workers);
  return results;
}
