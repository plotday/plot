import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

import type { LLMClient, LLMInputs, LLMOutput } from "./llm-client";

export type CachedLlmClient = LLMClient & {
  stats: { hits: number; misses: number };
};

export function hashInputs(
  model: string,
  promptTemplateId: string,
  inputs: LLMInputs
): string {
  const normalized = {
    model,
    promptTemplateId,
    system: inputs.system,
    user: inputs.user,
    allowedPriorityIds: [...inputs.allowedPriorityIds].sort(),
  };
  return createHash("sha256").update(JSON.stringify(normalized)).digest("hex");
}

export type CacheOpts = {
  client: LLMClient;
  cacheDir: string;
  namespace: string;
  promptTemplateId: string;
};

export function cachedLlmClient(opts: CacheOpts): CachedLlmClient {
  const stats = { hits: 0, misses: 0 };
  const nsDir = join(opts.cacheDir, opts.namespace);
  return {
    id: opts.client.id,
    stats,
    async classify(inputs: LLMInputs): Promise<LLMOutput> {
      const h = hashInputs(opts.client.id, opts.promptTemplateId, inputs);
      const path = join(nsDir, `${h}.json`);
      try {
        const text = await readFile(path, "utf-8");
        const parsed = JSON.parse(text) as { response: LLMOutput };
        stats.hits++;
        // Replays carry the originally-recorded usage (if any) so callers
        // can account replayed tokens separately from live ones.
        return { ...parsed.response, fromCache: true };
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
      }
      const response = await opts.client.classify(inputs);
      stats.misses++;
      await mkdir(nsDir, { recursive: true });
      await writeFile(
        path,
        JSON.stringify(
          {
            inputHash: h,
            model: opts.client.id,
            promptTemplateId: opts.promptTemplateId,
            response,
            timestamp: new Date().toISOString(),
          },
          null,
          2
        )
      );
      return response;
    },
  };
}
