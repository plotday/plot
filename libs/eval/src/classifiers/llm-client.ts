import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { generateObject } from "ai";
import {
  LLMResponseSchema,
  type LLMClient,
  type LLMInputs,
  type LLMOutput,
  type LLMUsage,
} from "@plotday/classifier";

export type { LLMClient, LLMInputs, LLMOutput, LLMUsage };

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
      // ai v6 reports usage as `inputTokens`/`outputTokens`, each possibly
      // undefined; only attach usage when both are known so consumers can
      // count un-priced calls (missing usage) separately.
      const usage =
        typeof result.usage?.inputTokens === "number" &&
        typeof result.usage?.outputTokens === "number"
          ? {
              inputTokens: result.usage.inputTokens,
              outputTokens: result.usage.outputTokens,
            }
          : undefined;
      const obj = result.object;
      const pid = obj.priority_id;
      if (pid !== null && !allowed.has(pid)) {
        return {
          priorityId: null,
          rationale: `out-of-set priorityId returned: ${pid}`,
          usage,
        };
      }
      return { priorityId: pid, rationale: obj.rationale, usage };
    },
  };
}
