import { z } from "zod";

export type LLMInputs = {
  system: string;
  user: string;
  allowedPriorityIds: string[];
};

/** Token usage for a single underlying provider call. */
export type LLMUsage = { inputTokens: number; outputTokens: number };

export type LLMOutput = {
  priorityId: string | null;
  rationale: string;
  /** Per-call token usage, when the provider reports it. */
  usage?: LLMUsage;
  /**
   * True when this output was replayed from a cache rather than a live
   * provider call. Set ONLY by cache wrappers (e.g. eval's cachedLlmClient).
   */
  fromCache?: boolean;
};

export interface LLMClient {
  /** Stable identifier (used in cache key — include model + provider). */
  id: string;
  classify(inputs: LLMInputs): Promise<LLMOutput>;
}

export const LLMResponseSchema = z.object({
  priority_id: z.string().nullable(),
  rationale: z.string().default(""),
});
