import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  DEFAULTS,
  DEFAULTS_LLM,
  makeHybridClassifier,
  makeHybridLlmClassifier,
  type Classifier,
  type LLMClient,
} from "@plotday/classifier";

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

const REGISTRY: Map<string, Classifier> = new Map();

export function registerClassifier(c: Classifier): void {
  REGISTRY.set(c.name, c);
}

export function registerVariant(name: string, classifier: Classifier): void {
  if (classifier.name !== name) {
    throw new Error(
      `registerVariant: classifier.name "${classifier.name}" must equal name "${name}"`
    );
  }
  REGISTRY.set(name, classifier);
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

registerClassifier(sqlCurrentClassifier);
registerVariant(
  "ts:hybrid:default",
  makeHybridClassifier("ts:hybrid:default", DEFAULTS)
);
registerVariant(
  "ts:hybrid-llm:default",
  makeHybridLlmClassifier("ts:hybrid-llm:default", {
    params: DEFAULTS_LLM,
    llmClientFor: evalLlmClientFor(
      DEFAULTS_LLM.llm!.model,
      DEFAULTS_LLM.llm!.cacheNamespace
    ),
  })
);
registerVariant(
  "ts:hybrid-llm:tight-gates",
  makeHybridLlmClassifier("ts:hybrid-llm:tight-gates", {
    params: {
      ...DEFAULTS_LLM,
      highConfidenceFloor: 0.55,
      marginFloor: 0.12,
    },
    llmClientFor: evalLlmClientFor(
      DEFAULTS_LLM.llm!.model,
      DEFAULTS_LLM.llm!.cacheNamespace
    ),
  })
);
