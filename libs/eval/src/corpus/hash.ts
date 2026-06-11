/**
 * Hashes an arbitrary string into a deterministic, well-formed (v4-shaped)
 * UUID. Used for synthetic ids that must be stable across runs: `twist:*`
 * author slugs (corpus/load.ts) and candidate-thread ids derived from case
 * ids (runner/run.ts).
 *
 * IMPORTANT: the outputs of this function are baked into frozen fixture
 * snapshots (e.g. tests/fixtures/kris-v1-expected.json). It must hash the
 * RAW input exactly as written — no namespacing, prefixing, or algorithm
 * tweaks — or those snapshots (and v1 byte-identical behavior) break.
 */
export function deterministicUuid(input: string): string {
  let h1 = 0x811c9dc5;
  let h2 = 0xdeadbeef;
  for (let i = 0; i < input.length; i++) {
    h1 = Math.imul(h1 ^ input.charCodeAt(i), 16777619) >>> 0;
    h2 = Math.imul(h2 ^ input.charCodeAt(i), 2654435761) >>> 0;
  }
  const a = h1.toString(16).padStart(8, "0");
  const b = (h2 >>> 16).toString(16).padStart(4, "0");
  const c = ((h1 ^ h2) >>> 16).toString(16).padStart(4, "0");
  const d = (h2 & 0xffff).toString(16).padStart(4, "0");
  const e = (
    (Math.imul(h1, h2) >>> 0).toString(16) +
    (Math.imul(h1 ^ h2, 0x9e3779b1) >>> 0).toString(16)
  )
    .padStart(12, "0")
    .slice(0, 12);
  return `${a}-${b}-4${c.slice(1)}-8${d.slice(1)}-${e}`;
}
