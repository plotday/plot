import { createAnthropic } from "@ai-sdk/anthropic";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { generateObject, type LanguageModel } from "ai";
import { z } from "zod";

import { getBuilderDocumentation } from "@plotday/twister/creator-docs";
import { TWIST_GUIDE } from "@plotday/twister/twist-guide";

import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import { buildTwist } from "./builder";
import type { TwistSource } from "./types";
import { captureGenerationFailure } from "../utils/twist-events";

/**
 * Model-facing schema. Gemini's structured-output schema (an OpenAPI subset)
 * cannot express dynamic-key objects (z.record) — models return empty
 * objects for such fields — so files and dependencies are arrays of named
 * entries here and are mapped back to the Record-shaped TwistSource
 * immediately after generation. Claude handles the array shape equally well.
 */
const generatedTwistSchema = z.object({
  displayName: z.string(),
  files: z.array(
    z.object({
      path: z.string(),
      content: z.string(),
    })
  ),
  dependencies: z.array(
    z.object({
      name: z.string(),
      version: z.string(),
    })
  ),
});

function toTwistSource(
  generated: z.infer<typeof generatedTwistSchema>
): TwistSource {
  const files: Record<string, string> = {};
  for (const file of generated.files) {
    files[file.path] = file.content; // duplicate paths: last entry wins
  }
  const dependencies: Record<string, string> = {};
  for (const dep of generated.dependencies) {
    dependencies[dep.name] = dep.version;
  }
  return { displayName: generated.displayName, files, dependencies };
}

export const DEFAULT_GENERATION_MODEL = "gemini-3.1-pro-preview";

/**
 * Structured telemetry emitted during generation. Consumed by the eval
 * harness (workers/api/evals); optional and side-effect free for all other
 * callers.
 */
export type GenerateAttemptEvent =
  | { type: "attempt_start"; attempt: number }
  | {
      type: "llm_complete";
      attempt: number;
      durationMs: number;
      usage?: {
        inputTokens?: number;
        outputTokens?: number;
        cacheReadInputTokens?: number;
        cacheCreationInputTokens?: number;
      };
    }
  | {
      type: "build_complete";
      attempt: number;
      durationMs: number;
      success: boolean;
      errors?: string[];
    };

function safeEmit(
  onEvent: ((event: GenerateAttemptEvent) => void) | undefined,
  event: GenerateAttemptEvent
) {
  if (!onEvent) return;
  try {
    onEvent(event);
  } catch {
    // Telemetry listeners must never affect generation.
  }
}

function extractUsage(result: {
  usage?: { inputTokens?: number; outputTokens?: number; cachedInputTokens?: number };
  providerMetadata?: Record<string, Record<string, unknown>>;
}): Extract<GenerateAttemptEvent, { type: "llm_complete" }>["usage"] {
  const usage = result.usage;
  const anthropic = result.providerMetadata?.anthropic ?? {};
  const google = result.providerMetadata?.google ?? {};
  if (!usage && !result.providerMetadata) return undefined;
  return {
    inputTokens: usage?.inputTokens,
    outputTokens: usage?.outputTokens,
    cacheReadInputTokens:
      typeof anthropic.cacheReadInputTokens === "number"
        ? anthropic.cacheReadInputTokens
        : typeof google.cachedContentTokenCount === "number"
          ? google.cachedContentTokenCount
          : usage?.cachedInputTokens,
    cacheCreationInputTokens:
      typeof anthropic.cacheCreationInputTokens === "number"
        ? anthropic.cacheCreationInputTokens
        : undefined,
  };
}

/**
 * Resolve the LanguageModel for a generation model id, routed through the
 * Cloudflare AI Gateway. Providers are selected by model-id prefix so
 * callers (notably the eval harness's --model flag) can A/B across vendors:
 *   gemini-* → Google AI Studio (same wiring as utils/system-model.ts)
 *   claude-* → Anthropic
 */
function resolveGenerationModel(
  env: Bindings,
  modelId: string,
  skipCache: boolean
): LanguageModel {
  const gatewayBaseUrl = `https://gateway.ai.cloudflare.com/v1/${env.AI_GATEWAY_ACCOUNT_ID}/${env.AI_GATEWAY_ID}`;
  const headers: Record<string, string> = {
    "cf-aig-authorization": `Bearer ${env.AI_GATEWAY_TOKEN}`,
    ...(skipCache ? { "cf-aig-skip-cache": "true" } : {}),
  };
  if (modelId.startsWith("gemini")) {
    if (!env.GOOGLE_GENERATIVE_AI_API_KEY) {
      throw new Error("GOOGLE_GENERATIVE_AI_API_KEY is missing");
    }
    const google = createGoogleGenerativeAI({
      baseURL: `${gatewayBaseUrl}/google-ai-studio/v1beta`,
      apiKey: env.GOOGLE_GENERATIVE_AI_API_KEY,
      headers,
    });
    return google(modelId);
  }
  if (modelId.startsWith("claude")) {
    if (!env.ANTHROPIC_API_KEY) {
      throw new Error("ANTHROPIC_API_KEY is missing");
    }
    const anthropic = createAnthropic({
      baseURL: `${gatewayBaseUrl}/anthropic`,
      apiKey: env.ANTHROPIC_API_KEY,
      headers,
    });
    return anthropic(modelId);
  }
  throw new Error(`Unsupported generation model: ${modelId}`);
}

export interface GenerateTwistOptions {
  spec: string;
  env: Bindings;
  onProgress?: (message: string) => void;
  // Optional user for PostHog attribution of generation failures.
  userId?: string | null;
  // Override the generation model (eval harness A/B). Default unchanged.
  model?: string;
  // Structured telemetry (eval harness). Errors in the listener are swallowed.
  onEvent?: (event: GenerateAttemptEvent) => void;
  // Bypass AI Gateway response caching (cf-aig-skip-cache) so repeat runs
  // measure real generations. Set by the eval harness; default false —
  // production keeps gateway caching.
  skipGatewayCache?: boolean;
}

/**
 * Generates a twist source from a specification using an LLM (Gemini by default).
 *
 * This function uses an iterative approach with error correction:
 * 1. Generate source from spec using the model
 * 2. Validate by building in sandbox
 * 3. If build errors, provide feedback to the model and retry
 * 4. Repeat up to 3 times
 * 5. Return valid source or throw error
 *
 * The system prompt is structured for optimal prompt caching:
 * - TWIST_GUIDE (large, static) comes first for caching
 * - Role/instructions (small, static) follow
 * - Variable content (spec/errors) goes in the user prompt
 *
 * @param options - Configuration object
 * @param options.spec - Markdown specification describing the twist functionality
 * @param options.env - Bindings containing Sandbox
 * @param options.onProgress - Optional callback for progress updates
 * @returns Promise resolving to valid twist source
 * @throws Error if generation fails after max attempts
 */
export async function generateTwist({
  spec,
  env,
  onProgress,
  userId,
  model,
  onEvent,
  skipGatewayCache,
}: GenerateTwistOptions): Promise<TwistSource> {
  let currentAttempt = 0;
  try {
    return await generateTwistInner({
      spec,
      env,
      onProgress,
      model,
      onEvent,
      skipGatewayCache,
      onAttempt: (n) => {
        currentAttempt = n;
      },
    });
  } catch (error) {
    await captureGenerationFailure({
      env,
      userId,
      error,
      specLength: spec.length,
      attempt: currentAttempt || undefined,
    });
    throw error;
  }
}

async function generateTwistInner({
  spec,
  env,
  onProgress,
  model: modelOverride,
  onEvent,
  skipGatewayCache,
  onAttempt,
}: {
  spec: string;
  env: Bindings;
  onProgress?: (message: string) => void;
  model?: string;
  onEvent?: (event: GenerateAttemptEvent) => void;
  skipGatewayCache?: boolean;
  onAttempt: (n: number) => void;
}): Promise<TwistSource> {
  if (
    !env.AI_GATEWAY_ACCOUNT_ID ||
    !env.AI_GATEWAY_ID ||
    !env.AI_GATEWAY_TOKEN
  ) {
    throw new Error("AI Gateway configuration is missing");
  }

  const modelId = modelOverride ?? DEFAULT_GENERATION_MODEL;
  const model = resolveGenerationModel(env, modelId, skipGatewayCache ?? false);

  const MAX_ATTEMPTS = 3;
  let attempt = 0;
  let previousSource: TwistSource | null = null;
  let previousErrors: string[] | null = null;

  while (attempt < MAX_ATTEMPTS) {
    attempt++;
    onAttempt(attempt);
    safeEmit(onEvent, { type: "attempt_start", attempt });

    // Report progress
    onProgress?.(
      attempt === 1 ? "Generating twist code" : "Adjusting twist code"
    );

    // Build the prompt based on whether this is a retry
    let userPrompt: string;

    if (attempt === 1) {
      // First attempt - just spec and guidance
      userPrompt = `Generate a Plot twist based on this specification:

${spec}

Requirements:
- "displayName" must be a concise, human-readable title for the twist (e.g., "Google Calendar Sync", "Task Manager")
- Extract the displayName from the specification based on the twist's purpose
- "files" must include an entry whose path is "index.ts" — the entry point
- The index.ts file must export a default class extending Twist
`;
    } else {
      // Retry attempt - include previous attempt and errors
      userPrompt = `Your previous attempt to generate the twist had build errors.

Previous source you generated:
\`\`\`json
${JSON.stringify(previousSource, null, 2)}
\`\`\`

Build errors:
${previousErrors?.join("\n\n")}

Please fix these errors and generate a corrected version.`;
    }

    // Get complete SDK type definitions with import paths
    const sdkDocs = getBuilderDocumentation();

    // System prompt structured for optimal prompt caching:
    // 1. SDK type definitions (largest, most static) - FIRST for best caching
    // 2. TWIST_GUIDE (large, static) - SECOND for caching
    // 3. Instructions (small, static) - THIRD
    // Variable content (spec, errors) goes in user prompt to preserve cache
    const systemPrompt = `You are an expert at generating Plot twists.

${sdkDocs}

${TWIST_GUIDE}`;

    // Call the model (Gemini by default, Claude via override) through the
    // Cloudflare AI Gateway.
    // Output limit: non-streaming generateObject keeps responses under SDK HTTP
    // timeouts with max ~16K tokens. Current models support far larger outputs, but
    // we don't stream here and a non-trivial twist typically fits well under 16K.
    //
    // Prompt caching: the system prompt is large and identical across retries and
    // callers. Anthropic needs the explicit cache_control ephemeral marker
    // (attached only for claude-* models); Gemini 2.5+/3 applies implicit
    // context caching to large repeated prefixes, so a plain string suffices.
    const llmStart = Date.now();
    const result = await generateObject({
      model,
      schema: generatedTwistSchema,
      schemaName: "TwistSource",
      schemaDescription:
        'Twist source code: a files array (each entry has a path like "index.ts" and the full file content) plus an npm dependencies array (name + version).',
      maxOutputTokens: 16_000,
      instructions: modelId.startsWith("claude")
        ? {
            role: "system",
            content: systemPrompt,
            providerOptions: {
              anthropic: { cacheControl: { type: "ephemeral" } },
            },
          }
        : systemPrompt,
      messages: [{ role: "user", content: userPrompt }],
    });
    safeEmit(onEvent, {
      type: "llm_complete",
      attempt,
      durationMs: Date.now() - llmStart,
      usage: extractUsage(result),
    });

    // Map the model's array-shaped response back into the Record-shaped
    // TwistSource. Zod already validated the array shape above.
    const source: TwistSource = toTwistSource(result.object);
    source.dependencies = {
      ...source.dependencies,
      "@plotday/twister": "latest",
    };

    // Validate required index.ts file exists
    if (!source.files["index.ts"]) {
      throw new Error("Generated connector is missing required 'index.ts' file");
    }

    // Try to build the twist
    const buildStart = Date.now();
    const buildResult = await buildTwist(source, env, onProgress);
    safeEmit(onEvent, {
      type: "build_complete",
      attempt,
      durationMs: Date.now() - buildStart,
      success: buildResult.success,
      errors: buildResult.success ? undefined : buildResult.errors,
    });

    if (buildResult.success) {
      // Success! Return the source
      return source;
    }

    // Build failed - store for retry
    previousSource = source;
    previousErrors = buildResult.errors;

    const logger = createLogger();
    logger.warn("Twist build errors on attempt", {
      attempt,
      errors: previousErrors?.join("\n\n"),
    });

    if (attempt === MAX_ATTEMPTS) {
      // Max attempts reached
      throw new Error(
        `Failed to generate valid twist after ${MAX_ATTEMPTS} attempts. Final errors:\n${buildResult.errors.join(
          "\n\n"
        )}`
      );
    }

    // Continue to next attempt
  }

  throw new Error("Unexpected: loop exited without returning or throwing");
}
