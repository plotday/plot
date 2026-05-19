import {
  DEFAULTS_LLM,
  makeHybridLlmClassifier,
  type Classifier,
  type LLMClient,
} from "@plotday/classifier";

import { kvBudget } from "./kv-budget";
import { kvLlmCache } from "./kv-cache";
import { workerGeminiClient } from "./worker-gemini-client";

export type ClassifierEnv = {
  readonly LLM_CACHE: KVNamespace;
  readonly GOOGLE_GENERATIVE_AI_API_KEY: string;
};

const SINGLETON_KEY = Symbol.for("@plotday/classifier-runtime/production");

type Holder = { classifier: Classifier; kv: KVNamespace };

/**
 * Returns a cached production classifier instance for this Worker
 * process. The classifier is constructed lazily on first call; later
 * calls reuse it. Cached against the KV namespace identity so a Worker
 * with multiple bindings (test/dev) can disambiguate; in practice
 * production has exactly one.
 */
export function getProductionClassifier(env: ClassifierEnv): Classifier {
  const global = globalThis as unknown as { [SINGLETON_KEY]?: Holder };
  const cached = global[SINGLETON_KEY];
  if (cached && cached.kv === env.LLM_CACHE) return cached.classifier;

  const llm = DEFAULTS_LLM.llm!;
  const llmClientFor = (promptId: string): LLMClient => {
    const client = workerGeminiClient(
      env.GOOGLE_GENERATIVE_AI_API_KEY,
      llm.model
    );
    return kvLlmCache({ client, kv: env.LLM_CACHE, promptId });
  };

  const classifier = makeHybridLlmClassifier("ts:hybrid-llm:production", {
    params: DEFAULTS_LLM,
    llmClientFor,
    consumeBudget: kvBudget(env.LLM_CACHE),
  });
  global[SINGLETON_KEY] = { classifier, kv: env.LLM_CACHE };
  return classifier;
}
