import { DEFAULTS_LLM, type HybridParams } from "@plotday/classifier";

// Derived from Object.keys(DEFAULTS_LLM) so new HybridParams fields are
// automatically known without hand-maintaining this list. Nested keys are
// NOT validated — only the top-level keys of the overrides object are checked.
const KNOWN_HYBRID_PARAMS_KEYS = new Set(Object.keys(DEFAULTS_LLM));

/**
 * Recursive plain-object merge for parameter sweeps: objects merge,
 * arrays/primitives replace. Returns a NEW object — `base` is never
 * mutated (untouched subtrees are shared by reference, which is safe
 * because nothing downstream mutates params).
 *
 * Only plain objects (prototype Object.prototype or null) merge; class
 * instances, arrays, Dates, etc. replace wholesale.
 *
 * Throws if `overrides` contains top-level keys that are not valid
 * HybridParams keys — catches typos (e.g. "originBonsu") that would
 * otherwise silently no-op and waste an entire tuning run.
 */
export function deepMergeParams(
  base: HybridParams,
  overrides: Record<string, unknown>
): HybridParams {
  const unknownKeys = Object.keys(overrides).filter(
    (k) => !KNOWN_HYBRID_PARAMS_KEYS.has(k)
  );
  if (unknownKeys.length > 0) {
    throw new Error(
      `deepMergeParams: unknown HybridParams key(s): ${unknownKeys.join(", ")}. ` +
        `Known keys: ${[...KNOWN_HYBRID_PARAMS_KEYS].sort().join(", ")}`
    );
  }
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
