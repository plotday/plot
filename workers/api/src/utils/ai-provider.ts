import { createAnthropic } from "@ai-sdk/anthropic";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { createOpenAI } from "@ai-sdk/openai";
import { generateText } from "ai";
import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import type { AiProviderConfig } from "../twist/tools/ai";

/**
 * BYOK removed in B4 — always returns undefined so callers use the built-in
 * Plot AI provider. The ai_preference.builtin_ai_key_id column and ai_key table
 * were dropped in the B4 Task 6 contract migration.
 *
 * Callers in summary.ts and sync/threads.ts guard on `if (providerConfig)` before
 * calling summarizeWithProvider, so returning undefined here routes them to the
 * default Workers AI path unchanged.
 */
// eslint-disable-next-line @typescript-eslint/no-unused-vars
export async function loadBuiltinProviderConfig(
  _db: Kysely<DB>,
  _userId: string,
  _env: Bindings
): Promise<AiProviderConfig | undefined> {
  return undefined;
}

/**
 * Generate a summary using the user's configured builtin AI provider.
 * Falls back to the system prompt + messages pattern used by Workers AI.
 */
export async function summarizeWithProvider(
  config: AiProviderConfig,
  body: string
): Promise<string | null> {
  let provider: any;
  let modelName: string;

  switch (config.provider) {
    case "openai":
      provider = createOpenAI({ apiKey: config.apiKey });
      modelName = "gpt-4o-mini";
      break;
    case "anthropic":
      provider = createAnthropic({ apiKey: config.apiKey });
      modelName = "claude-haiku-4-5-20251001";
      break;
    case "google":
      provider = createGoogleGenerativeAI({ apiKey: config.apiKey });
      modelName = "gemini-2.5-flash-lite-preview-06-17";
      break;
    case "custom":
      provider = createOpenAI({ apiKey: config.apiKey, baseURL: config.baseUrl });
      modelName = config.fastModel || "gpt-4o-mini";
      break;
  }

  const model = config.provider === "custom" ? provider.chat(modelName) : provider(modelName);

  try {
    const result = await generateText({
      model,
      instructions: "You name items in a productivity app. Create a short title for the user-provided action or note. Do not wrap the title in quotes. Respond only with the title.",
      prompt: body,
      maxOutputTokens: 64,
    });

    return result.text?.replace(/^"(.*)"$/, "$1")?.trim() || null;
  } catch (error: any) {
    console.error("[summary] Provider error details", {
      provider: config.provider,
      baseUrl: config.baseUrl,
      model: modelName,
      responseBody: error.responseBody ?? error.data ?? error.cause,
      statusCode: error.statusCode,
    });
    throw error;
  }
}
