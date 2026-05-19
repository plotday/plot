import { z } from "zod";

export type LLMInputs = {
  system: string;
  user: string;
  allowedPriorityIds: string[];
};

export type LLMOutput = {
  priorityId: string | null;
  rationale: string;
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
