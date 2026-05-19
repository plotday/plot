import type { LLMClient, LLMInputs, LLMOutput } from "@plotday/classifier";

import { sha256Hex } from "./canonical-input";

/** 30 days, in seconds. */
const CACHE_TTL_SECONDS = 30 * 24 * 60 * 60;

export type KvCacheStats = { hits: number; misses: number };

export type KvLlmCacheOpts = {
  /** Underlying classifier (e.g. Gemini). */
  client: LLMClient;
  /** Cloudflare KV namespace shared across the two workers. */
  kv: KVNamespace;
  /** Prompt template id; bump to invalidate the entire cache for one stage. */
  promptId: string;
};

/**
 * KV-backed cache wrapper for an LLMClient. The eval side has a file-
 * cache equivalent; both hash the same fields so identical inputs return
 * identical responses regardless of where the call was made.
 *
 * The cache key includes promptId (so changing the prompt invalidates
 * cached responses), the model id (LLMClient.id), and a hash of the
 * rendered inputs (system, user, allowedPriorityIds sorted). The hashed
 * shape is byte-deterministic as long as the prompt builders themselves
 * are deterministic — see `canonical-input.ts` + the parity test for
 * the regression guard against builder drift.
 */
export function kvLlmCache(opts: KvLlmCacheOpts): LLMClient & {
  stats: KvCacheStats;
} {
  const stats: KvCacheStats = { hits: 0, misses: 0 };
  return {
    id: opts.client.id,
    stats,
    async classify(inputs: LLMInputs): Promise<LLMOutput> {
      const key = await cacheKey(opts.client.id, opts.promptId, inputs);

      const hit = await opts.kv.get(key);
      if (hit !== null) {
        try {
          const parsed = JSON.parse(hit) as LLMOutput;
          stats.hits++;
          return parsed;
        } catch {
          // Corrupt entry — fall through and overwrite.
        }
      }

      const response = await opts.client.classify(inputs);
      stats.misses++;

      try {
        await opts.kv.put(key, JSON.stringify(response), {
          expirationTtl: CACHE_TTL_SECONDS,
        });
      } catch {
        // Cache-write failure must not break classification.
      }
      return response;
    },
  };
}

async function cacheKey(
  modelId: string,
  promptId: string,
  inputs: LLMInputs
): Promise<string> {
  const normalized = JSON.stringify({
    model: modelId,
    promptId,
    system: inputs.system,
    user: inputs.user,
    allowedPriorityIds: [...inputs.allowedPriorityIds].sort(),
  });
  const hash = await sha256Hex(normalized);
  return `llm-classify:${promptId}:${hash}`;
}
