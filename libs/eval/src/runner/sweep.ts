import type { HybridParams } from "@plotday/classifier";

/**
 * Recursive plain-object merge for parameter sweeps: objects merge,
 * arrays/primitives replace. Returns a NEW object — `base` is never
 * mutated (untouched subtrees are shared by reference, which is safe
 * because nothing downstream mutates params).
 *
 * Only plain objects (prototype Object.prototype or null) merge; class
 * instances, arrays, Dates, etc. replace wholesale.
 */
export function deepMergeParams(
  base: HybridParams,
  overrides: Record<string, unknown>
): HybridParams {
  return mergeObjects(
    base as unknown as Record<string, unknown>,
    overrides
  ) as unknown as HybridParams;
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  if (v === null || typeof v !== "object") return false;
  const proto: unknown = Object.getPrototypeOf(v);
  return proto === Object.prototype || proto === null;
}

function mergeObjects(
  base: Record<string, unknown>,
  overrides: Record<string, unknown>
): Record<string, unknown> {
  const out: Record<string, unknown> = { ...base };
  for (const [key, value] of Object.entries(overrides)) {
    const existing = base[key];
    out[key] =
      isPlainObject(existing) && isPlainObject(value)
        ? mergeObjects(existing, value)
        : value;
  }
  return out;
}
