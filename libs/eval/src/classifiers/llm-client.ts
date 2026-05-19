import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { generateObject } from "ai";
import {
  LLMResponseSchema,
  type LLMClient,
  type LLMInputs,
  type LLMOutput,
} from "@plotday/classifier";

export type { LLMClient, LLMInputs, LLMOutput };

export function makeGeminiClient(model: string): LLMClient {
  const apiKey =
    process.env.GOOGLE_GENERATIVE_AI_API_KEY ?? process.env.GEMINI_API_KEY;
  if (!apiKey) {
    throw new Error(
      "makeGeminiClient: GOOGLE_GENERATIVE_AI_API_KEY (or GEMINI_API_KEY) env var is required to call the real Gemini API."
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
