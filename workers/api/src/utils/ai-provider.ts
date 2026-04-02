import { createAnthropic } from "@ai-sdk/anthropic";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { createOpenAI } from "@ai-sdk/openai";
import { generateText } from "ai";
import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import { decrypt } from "./encryption";
import type { AiProviderConfig } from "../twist/tools/ai";

/**
 * Load the user's builtin AI provider config from ai_preference + ai_key.
 * Returns undefined if user prefers Plot AI (default).
 */
export async function loadBuiltinProviderConfig(
  db: Kysely<DB>,
  userId: string,
  env: Bindings
): Promise<AiProviderConfig | undefined> {
  const pref = await db
    .selectFrom("ai_preference")
    .select("builtin_ai_key_id")
    .where("user_id", "=", userId)
    .executeTakeFirst();

  if (!pref?.builtin_ai_key_id) return undefined;

  const row = await db
    .selectFrom("ai_key")
    .select(["provider", "encrypted_key", "iv", "custom_base_url", "fast_model", "thinking_model"])
    .where("id", "=", pref.builtin_ai_key_id)
    .executeTakeFirst();

  if (!row) return undefined;

  const apiKey = await decrypt(row.encrypted_key, row.iv, env.AI_KEY_ENCRYPTION_KEY);

  return {
    provider: row.provider as AiProviderConfig["provider"],
    apiKey,
    ...(row.custom_base_url ? { baseUrl: row.custom_base_url } : {}),
    ...(row.fast_model ? { fastModel: row.fast_model } : {}),
    ...(row.thinking_model ? { thinkingModel: row.thinking_model } : {}),
  };
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

  const result = await generateText({
    model: provider(modelName),
    system: "You name items in a productivity app. Create a short title for the user-provided action or note. Do not wrap the title in quotes. Respond only with the title.",
    prompt: body,
    maxOutputTokens: 64,
  });

  return result.text?.replace(/^"(.*)"$/, "$1")?.trim() || null;
}
