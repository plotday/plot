import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  DEFAULTS,
  DEFAULTS_LLM,
  makeHybridClassifier,
  makeHybridLlmClassifier,
  paramsHash,
  type Classifier,
  type ConsumeBudgetFn,
  type HybridParams,
  type LLMClient,
} from "@plotday/classifier";

import { deepMergeParams } from "../runner/sweep";
import { cachedLlmClient } from "./llm-cache";
import { makeGeminiClient } from "./llm-client";
import { sqlCurrentClassifier } from "./sql-current";

const ROOT = dirname(fileURLToPath(import.meta.url));
const CACHE_DIR = join(ROOT, "..", "..", ".cache", "llm");

/**
 * Eval-side LLM client factory: wraps the Gemini client with the
 * file-based cache, keyed on prompt template id. Workers code uses a
 * KV-backed equivalent.
 */
function evalLlmClientFor(model: string, cacheNamespace: string) {
  return (promptId: string): LLMClient =>
    cachedLlmClient({
      client: makeGeminiClient(model),
      cacheDir: CACHE_DIR,
      namespace: cacheNamespace,
      promptTemplateId: promptId,
    });
}

/**
 * Eval-side per-user LLM budget gate: always allow.
 *
 * The production cascade meters LLM calls with in-process per-user counters
 * (free tier: 5000/month, 100/day). A long sweep over one eval user would
 * exhaust those counters mid-run and silently turn LLM stages off, so later
 * grid points would be measured with a deterministically degraded cascade —
 * corrupting the comparison without any error. Evals measure configuration
 * quality, not production rate limits, so EVERY eval-registered LLM variant
 * (default, tight-gates, ad-hoc) gets this unlimited gate.
 *
 * Exported so tests can inject the exact same gate the registry uses.
 */
export const evalUnlimitedBudget: ConsumeBudgetFn = () => true;

const REGISTRY: Map<string, Classifier> = new Map();

/**
 * Resolved HybridParams for every registry-constructed variant, so ad-hoc
 * variants can use any of them (including previously registered ad-hoc
 * variants) as a base for overrides.
 */
const VARIANT_PARAMS: Map<string, HybridParams> = new Map();

export function registerClassifier(c: Classifier): void {
  REGISTRY.set(c.name, c);
}

/**
 * Register a classifier under `name` in REGISTRY only — it does NOT write to
 * VARIANT_PARAMS. As a result, classifiers registered through this function
 * cannot serve as the `--base` for ad-hoc variants built by
 * `makeAdhocLlmVariant` / `makeAdhocVariantFromFile`, because those lookups
 * resolve params from VARIANT_PARAMS.
 *
 * Intended for two narrow use cases:
 *   1. **Test stubs** — fake classifiers that need a name but carry no
 *      HybridParams (e.g. the SQL baseline stub).
 *   2. **Non-HybridParams classifiers** — e.g. `sqlCurrentClassifier`, which
 *      has its own internal configuration and is not parameterised via
 *      HybridParams at all.
 *
 * For HybridParams-based variants that should be ad-hoc-derivable, use the
 * private `registerHybridVariant` helper instead (which writes both maps).
 */
export function registerVariant(name: string, classifier: Classifier): void {
  if (classifier.name !== name) {
    throw new Error(
      `registerVariant: classifier.name "${classifier.name}" must equal name "${name}"`
    );
  }
  REGISTRY.set(name, classifier);
}

/**
 * Resolved HybridParams for a registry-constructed variant — the base a
 * sweep's renormalization and overrides are computed against. Throws for
 * names registered without params (e.g. sql:current) or never registered.
 */
export function getVariantParams(name: string): HybridParams {
  const params = VARIANT_PARAMS.get(name);
  if (!params) {
    throw new Error(
      `Unknown variant "${name}" (no HybridParams registered). ` +
        `Known: ${[...VARIANT_PARAMS.keys()].join(", ")}`
    );
  }
  return params;
}

export function getClassifier(name: string): Classifier {
  const c = REGISTRY.get(name);
  if (!c) {
    throw new Error(
      `Unknown classifier: ${name}. Registered: ${[...REGISTRY.keys()].join(", ")}`
    );
  }
  return c;
}

export function listClassifiers(): string[] {
  return [...REGISTRY.keys()];
}

/**
 * Build + register a hybrid variant from resolved params: LLM cascade when
 * params.llm is configured, deterministic cascade otherwise. Every LLM
 * variant gets the unlimited budget gate (see evalUnlimitedBudget) so long
 * sweeps can't silently degrade mid-run.
 */
function registerHybridVariant(
  name: string,
  params: HybridParams
): Classifier {
  const classifier = params.llm
    ? makeHybridLlmClassifier(name, {
        params,
        llmClientFor: evalLlmClientFor(
          params.llm.model,
          params.llm.cacheNamespace
        ),
        consumeBudget: evalUnlimitedBudget,
      })
    : makeHybridClassifier(name, params);
  registerVariant(name, classifier);
  VARIANT_PARAMS.set(name, params);
  return classifier;
}

/**
 * Build and register an ad-hoc variant: `base`'s params deep-merged with
 * `overrides` (objects merge, arrays/primitives replace). Named
 * `<base>+params@<hash>` where the hash is FNV-1a over the key-sorted JSON
 * of the overrides, so the same base + overrides always yields the same
 * name (re-registration is idempotent). Weight validity is enforced by the
 * make* constructors (assertValidWeights), so partial weight overrides that
 * break sum-to-1 throw here.
 */
export function makeAdhocLlmVariant(
  overrides: Record<string, unknown>,
  base: string = "ts:hybrid-llm:default"
): Classifier {
  const baseParams = VARIANT_PARAMS.get(base);
  if (!baseParams) {
    throw new Error(
      `Unknown base "${base}" for ad-hoc variant. Known bases: ${[...VARIANT_PARAMS.keys()].join(", ")}`
    );
  }
  const merged = deepMergeParams(baseParams, overrides);
  // paramsHash canonicalizes (key-sorts) any value before hashing; its
  // HybridParams parameter type is nominal, so hashing the bare overrides
  // is safe and keeps the name independent of base-param evolution.
  const hash = paramsHash(overrides as unknown as HybridParams);
  return registerHybridVariant(`${base}+params@${hash}`, merged);
}

/**
 * CLI plumbing for `--params <file.json>`: read a JSON object of
 * HybridParams overrides from disk and register the ad-hoc variant.
 */
export function makeAdhocVariantFromFile(
  filePath: string,
  base?: string
): Classifier {
  const text = readFileSync(resolve(filePath), "utf-8");
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (err) {
    throw new Error(
      `--params ${filePath}: invalid JSON (${(err as Error).message})`
    );
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(
      `--params ${filePath}: must be a JSON object of HybridParams overrides`
    );
  }
  return makeAdhocLlmVariant(parsed as Record<string, unknown>, base);
}

registerClassifier(sqlCurrentClassifier);
registerHybridVariant("ts:hybrid:default", DEFAULTS);
registerHybridVariant("ts:hybrid-llm:default", DEFAULTS_LLM);
registerHybridVariant("ts:hybrid-llm:tight-gates", {
  ...DEFAULTS_LLM,
  highConfidenceFloor: 0.55,
  marginFloor: 0.12,
});
