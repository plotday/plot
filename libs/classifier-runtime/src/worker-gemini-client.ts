import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { generateObject } from "ai";

import {
  LLMResponseSchema,
  type LLMClient,
  type LLMInputs,
  type LLMOutput,
} from "@plotday/classifier";

/**
 * Build a Gemini-backed LLMClient suitable for Cloudflare Workers. The
 * provider is created lazily inside each call so the API key is read at
 * classify time (env.GOOGLE_GENERATIVE_AI_API_KEY) and not captured by
 * module-load closures.
 */
export function workerGeminiClient(apiKey: string, model: string): LLMClient {
  if (!apiKey) {
    throw new Error(
      "workerGeminiClient: GOOGLE_GENERATIVE_AI_API_KEY is required"
    );
  }
  const google = createGoogleGenerativeAI({ apiKey });
  return {
    id: `google:${model}`,
    async classify(inputs: LLMInputs): Promise<LLMOutput> {
      const allowed = new Set(inputs.allowedPriorityIds);
      const result = await generateObject({
        model: google(model),
        schema: LLMResponseSchema,
        system: inputs.system,
        prompt: inputs.user,
        temperature: 0,
        providerOptions: {
          google: {
            thinkingConfig: {
              thinkingLevel: "minimal",
              includeThoughts: false,
            },
          },
        },
      });
      const obj = result.object;
      const pid = obj.priority_id;
      if (pid !== null && !allowed.has(pid)) {
        return {
          priorityId: null,
          rationale: `out-of-set priorityId returned: ${pid}`,
        };
      }
      return { priorityId: pid, rationale: obj.rationale };
    },
  };
}
