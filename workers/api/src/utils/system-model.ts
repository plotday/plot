import { createGoogleGenerativeAI } from "@ai-sdk/google";
import type { LanguageModel } from "ai";

import type { Bindings } from "../env";

// Single source of truth for the model used by all SYSTEM (non-user-
// configurable) LLM calls: focus matching, priority suggestions, channel
// routing, and facet-filter derivation. Change the provider/model here and
// every system call site follows.
//
// Routed through the Cloudflare AI Gateway (observability + caching), matching
// the Plot-AI wiring in twist/tools/ai.ts. The model matches the Gemini model
// the production classifier uses (libs/classifier ts-hybrid defaults).
const SYSTEM_MODEL = "gemini-3-flash-preview";

/**
 * Provider options for system calls. Minimal thinking keeps these structured-
 * output calls fast and cheap; mirrors the production classifier. Spread into
 * the top-level `providerOptions` of a generateObject/generateText call.
 */
export const SYSTEM_PROVIDER_OPTIONS = {
  google: {
    thinkingConfig: {
      thinkingLevel: "minimal",
      includeThoughts: false,
    },
  },
} as const;

/**
 * Build the shared system LLM model, or null when the AI Gateway isn't
 * configured (dev / some test envs). A null return is the signal for callers
 * to take their non-LLM fallback path — it is not an error.
 */
export function createSystemModel(env: Bindings): LanguageModel | null {
  if (!env.AI_GATEWAY_ACCOUNT_ID || !env.AI_GATEWAY_ID || !env.AI_GATEWAY_TOKEN) {
    return null;
  }

  const gatewayBaseUrl = `https://gateway.ai.cloudflare.com/v1/${env.AI_GATEWAY_ACCOUNT_ID}/${env.AI_GATEWAY_ID}`;
  const google = createGoogleGenerativeAI({
    baseURL: `${gatewayBaseUrl}/google-ai-studio/v1beta`,
    apiKey: env.GOOGLE_GENERATIVE_AI_API_KEY,
    headers: { "cf-aig-authorization": `Bearer ${env.AI_GATEWAY_TOKEN}` },
  });

  return google(SYSTEM_MODEL);
}
