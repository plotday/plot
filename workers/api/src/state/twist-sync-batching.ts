// Pure helpers for sizing and packing TwistSync queue batches.
//
// Kept free of Durable Object / runtime imports so they can be unit-tested in
// the plain `node` vitest project without pulling in the whole twist runtime.

const textEncoder = new TextEncoder();

/**
 * UTF-8 byte length of a string.
 *
 * Cloudflare Queues enforces its 128 KB per-message limit on the UTF-8 byte
 * size of the serialized payload. `String.prototype.length` counts UTF-16 code
 * units, which undercounts any non-ASCII content (accented Latin, CJK, emoji),
 * so sizing batches by `.length` can let a batch slip over the byte limit and
 * fail with "Queue send failed: Payload Too Large".
 */
export function utf8ByteLength(value: string): number {
  return textEncoder.encode(value).length;
}

/**
 * Greedily pack pre-sized items into batches that stay under `maxBytes` and
 * `maxItems`. At least one item is always placed per batch, so an item larger
 * than `maxBytes` forms its own (oversized) batch rather than being dropped —
 * the caller is responsible for handling that singleton case.
 */
export function buildSizeAwareBatches<T extends { size: number }>(
  items: readonly T[],
  maxBytes: number,
  maxItems: number
): T[][] {
  const batches: T[][] = [];
  let current: T[] = [];
  let currentBytes = 0;

  for (const item of items) {
    if (
      current.length > 0 &&
      (currentBytes + item.size > maxBytes || current.length >= maxItems)
    ) {
      batches.push(current);
      current = [];
      currentBytes = 0;
    }
    current.push(item);
    currentBytes += item.size;
  }
  if (current.length > 0) {
    batches.push(current);
  }
  return batches;
}

/**
 * Split a batch into two roughly equal halves. Used to recover when a
 * multi-item batch is rejected as too large (e.g. when uncounted envelope
 * overhead such as tag changes pushes it over the limit): split and retry each
 * half so every item is still delivered.
 */
export function splitBatch<T>(batch: readonly T[]): [T[], T[]] {
  const mid = Math.floor(batch.length / 2);
  return [batch.slice(0, mid), batch.slice(mid)];
}
