import type { HybridParams } from "./ts-hybrid.defaults";

/**
 * Stable short hash of the resolved classifier parameters (weights, floors,
 * prompt ids, model). Stamped into the production classifier's name so every
 * classification_decision row attributes the decision to an exact
 * configuration. NOT cryptographic — FNV-1a over a key-sorted JSON
 * rendering; collisions are irrelevant for version discrimination.
 *
 * A key explicitly set to `undefined` hashes differently from an absent key
 * (it serializes as a literal `undefined` token) — omit unwanted keys rather
 * than setting them to `undefined`.
 */
export function paramsHash(params: HybridParams): string {
  const s = stableStringify(params);
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h = Math.imul(h ^ s.charCodeAt(i), 16777619) >>> 0;
  }
  return h.toString(16).padStart(8, "0");
}

function stableStringify(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record).sort();
  return `{${keys
    .map((k) => `${JSON.stringify(k)}:${stableStringify(record[k])}`)
    .join(",")}}`;
}
