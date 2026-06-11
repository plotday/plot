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

// ---------------------------------------------------------------------------
// Sweep spec parsing (--sweep)
// ---------------------------------------------------------------------------

/** One grid point of a sweep: human label + HybridParams overrides. */
export type SweepPoint = { label: string; overrides: Record<string, unknown> };

type SweepDimension = {
  /** Raw dimension text, for error messages. */
  raw: string;
  /** Dotted key path, e.g. "originBonus.exact". */
  path: string;
  keys: string[];
  values: unknown[];
};

/** Hard cap on values per range dimension — catches runaway step sizes. */
const MAX_RANGE_VALUES = 10_000;

/**
 * Parses a sweep spec into the cross product of its dimensions.
 *
 * Grammar: `;`-separated dimensions, each `path=values` where `path` is a
 * dotted HybridParams key path and `values` is either an inclusive numeric
 * range `start:end:step` or a `|`-separated list (numbers parse as numbers,
 * true/false as booleans, anything else stays a string). Example:
 *
 *   "scoreThreshold=0.05:0.2:0.05;aggregation.mode=top1|softmax"
 *
 * Weight dimensions (`weights.<component>`) are special-cased: each point's
 * overrides carry a FULL weights object with the swept component set and the
 * remaining components rescaled by (1 - newVal) / (1 - oldVal) against
 * `baseParams.weights`, so the sum stays 1 (assertValidWeights would reject
 * a bare partial override). At most one weights.* dimension is allowed —
 * renormalizing two swept components against each other is ambiguous.
 *
 * Point labels are `path=value` pairs joined with `;` in dimension order.
 * Top-level path keys are validated against HybridParams at parse time so a
 * typo'd sweep fails before any classification runs.
 */
export function parseSweepSpec(
  spec: string,
  baseParams: HybridParams
): SweepPoint[] {
  const dimTexts = spec
    .split(";")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (dimTexts.length === 0) {
    throw new Error("parseSweepSpec: empty sweep spec");
  }

  const dims: SweepDimension[] = [];
  let weightsDim: string | null = null;
  for (const raw of dimTexts) {
    const eq = raw.indexOf("=");
    if (eq <= 0) {
      throw new Error(
        `parseSweepSpec: dimension "${raw}" must have the form path=values`
      );
    }
    const path = raw.slice(0, eq).trim();
    const valuesText = raw.slice(eq + 1).trim();
    if (valuesText.length === 0) {
      throw new Error(`parseSweepSpec: dimension "${raw}" has no values`);
    }
    const keys = path.split(".");
    if (keys.some((k) => k.length === 0)) {
      throw new Error(
        `parseSweepSpec: dimension "${raw}" has an empty key path segment`
      );
    }
    if (!KNOWN_HYBRID_PARAMS_KEYS.has(keys[0]!)) {
      throw new Error(
        `parseSweepSpec: unknown HybridParams key "${keys[0]}" in dimension "${raw}". ` +
          `Known keys: ${[...KNOWN_HYBRID_PARAMS_KEYS].sort().join(", ")}`
      );
    }
    if (keys[0] === "weights" && keys.length > 1) {
      if (weightsDim !== null) {
        throw new Error(
          `parseSweepSpec: only one weights.* dimension is allowed per spec ` +
            `("${weightsDim}" and "${raw}") — renormalizing two swept weight ` +
            `components against each other is ambiguous`
        );
      }
      weightsDim = raw;
      validateWeightsDimension(raw, keys, baseParams);
    }
    dims.push({ raw, path, keys, values: parseValues(valuesText, raw) });
  }

  // Cross product, first dimension outermost.
  let points: { labelParts: string[]; overrides: Record<string, unknown> }[] = [
    { labelParts: [], overrides: {} },
  ];
  for (const dim of dims) {
    const next: typeof points = [];
    for (const point of points) {
      for (const value of dim.values) {
        next.push({
          labelParts: [...point.labelParts, `${dim.path}=${String(value)}`],
          overrides: mergeObjects(
            point.overrides,
            dimensionOverride(dim, value, baseParams)
          ),
        });
      }
    }
    points = next;
  }
  return points.map((p) => ({
    label: p.labelParts.join(";"),
    overrides: p.overrides,
  }));
}

function validateWeightsDimension(
  raw: string,
  keys: string[],
  baseParams: HybridParams
): void {
  const weights = baseParams.weights as unknown as Record<string, number>;
  if (keys.length !== 2 || !(keys[1]! in weights)) {
    throw new Error(
      `parseSweepSpec: "${raw}" does not name a weight component. ` +
        `Components: ${Object.keys(weights).join(", ")}`
    );
  }
  if (weights[keys[1]!] === 1) {
    throw new Error(
      `parseSweepSpec: cannot sweep "${raw}": base weights.${keys[1]} is 1, ` +
        `so there is no remaining weight mass to renormalize`
    );
  }
}

/**
 * Per-point override object for one dimension value. weights.* dimensions
 * produce a full renormalized weights object; everything else nests the
 * value under its dotted path ("originBonus.exact" → {originBonus:{exact:v}}).
 */
function dimensionOverride(
  dim: SweepDimension,
  value: unknown,
  baseParams: HybridParams
): Record<string, unknown> {
  if (dim.keys[0] === "weights" && dim.keys.length > 1) {
    return { weights: renormalizedWeights(dim, value, baseParams) };
  }
  let nested: unknown = value;
  for (let i = dim.keys.length - 1; i >= 0; i--) {
    nested = { [dim.keys[i]!]: nested };
  }
  return nested as Record<string, unknown>;
}

function renormalizedWeights(
  dim: SweepDimension,
  value: unknown,
  baseParams: HybridParams
): Record<string, number> {
  const component = dim.keys[1]!;
  if (typeof value !== "number") {
    throw new Error(
      `parseSweepSpec: weights dimension "${dim.raw}" requires numeric values ` +
        `(got "${String(value)}")`
    );
  }
  if (value < 0 || value >= 1) {
    // value === 1 is legal arithmetic but silently zeroes every other signal
    // (scale = 0) — a degenerate single-signal classifier nobody sweeps for.
    throw new Error(
      `parseSweepSpec: weights dimension "${dim.raw}" value ${value} must be in [0, 1)`
    );
  }
  const base = baseParams.weights as unknown as Record<string, number>;
  const scale = (1 - value) / (1 - base[component]!);
  const out: Record<string, number> = {};
  for (const [k, w] of Object.entries(base)) {
    out[k] = k === component ? value : w * scale;
  }
  return out;
}

function parseValues(text: string, raw: string): unknown[] {
  if (text.includes("|")) {
    const parts = text.split("|").map((s) => s.trim());
    if (parts.some((p) => p.length === 0)) {
      throw new Error(
        `parseSweepSpec: dimension "${raw}" has an empty list value`
      );
    }
    return parts.map(parseScalar);
  }
  const colonParts = text.split(":");
  if (colonParts.length === 3) return expandRange(colonParts, raw);
  if (colonParts.length === 2) {
    // No HybridParams value legitimately contains a single colon; this is
    // almost certainly a range with the step forgotten.
    throw new Error(
      `parseSweepSpec: dimension "${raw}" looks like an incomplete range — ` +
        `numeric ranges require exactly three parts: start:end:step`
    );
  }
  return [parseScalar(text)];
}

function expandRange(parts: string[], raw: string): number[] {
  const [start, end, step] = parts.map((p) => {
    const n = Number(p.trim());
    if (p.trim().length === 0 || !Number.isFinite(n)) {
      throw new Error(
        `parseSweepSpec: dimension "${raw}" has a non-numeric range part "${p}"`
      );
    }
    return n;
  }) as [number, number, number];
  if (step === 0) {
    throw new Error(`parseSweepSpec: dimension "${raw}" has a zero step`);
  }
  if ((end - start) * step < 0) {
    throw new Error(
      `parseSweepSpec: dimension "${raw}" step has the wrong sign for its range`
    );
  }
  // Inclusive of `end` within fp tolerance; values rounded to 1e-9 so labels
  // stay clean (0.30000000000000004 → 0.3).
  const eps = Math.abs(step) * 1e-6;
  const values: number[] = [];
  for (let i = 0; ; i++) {
    const v = Math.round((start + i * step) * 1e9) / 1e9;
    if (step > 0 ? v > end + eps : v < end - eps) break;
    values.push(v);
    if (values.length > MAX_RANGE_VALUES) {
      throw new Error(
        `parseSweepSpec: dimension "${raw}" expands to more than ${MAX_RANGE_VALUES} values`
      );
    }
  }
  return values;
}

function parseScalar(text: string): unknown {
  if (text === "true") return true;
  if (text === "false") return false;
  const n = Number(text);
  if (text.length > 0 && Number.isFinite(n)) return n;
  return text;
}
