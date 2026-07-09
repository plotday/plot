import { createAnthropic } from "@ai-sdk/anthropic";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { streamText, Output, type LanguageModel, type ModelMessage } from "ai";
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
    }
  | {
      type: "llm_retry";
      attempt: number;
      reason: "transient" | "output";
      retry: number;
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

/**
 * HTTP/network-shaped failures worth retrying with backoff: rate limits,
 * server errors, the AI SDK's own retry-exhaustion error, and common
 * transport-level failures surfaced as plain messages.
 */
export function isTransientLlmError(error: unknown): boolean {
  const status = (error as { statusCode?: number })?.statusCode;
  if (typeof status === "number") return status === 429 || status >= 500;
  const name = (error as Error)?.name ?? "";
  if (name === "AI_RetryError") return true;
  const message = (error as Error)?.message ?? "";
  return /ECONNRESET|ETIMEDOUT|fetch failed|network/i.test(message);
}

/**
 * The model produced no usable structured output (truncated response or
 * schema-validation failure) rather than a transport failure. Worth one
 * retry with a corrective nudge rather than aborting the whole attempt.
 */
export function isOutputProblemError(error: unknown): boolean {
  const name = (error as Error)?.name ?? "";
  return name === "AI_NoObjectGeneratedError" || name === "AI_NoOutputGeneratedError";
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

const TRANSIENT_MAX_RETRIES = 2;
const OUTPUT_MAX_RETRIES = 1;
const TRANSIENT_BACKOFF_MS = [1_000, 4_000];

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/**
 * Issue a single streamText call for the current conversation, retrying
 * within budget on LLM-level failures:
 * - Transient (rate limit/5xx/network): up to 2 retries with jittered
 *   backoff, conversation unchanged (the failure carries no useful signal
 *   for the model).
 * - Output problem (truncated/invalid structured output): up to 1 retry
 *   with a corrective user turn appended so the model knows to try again.
 * Budgets are per call (i.e. reset every build attempt); exhausting a
 * budget rethrows the final error unchanged so the caller's own
 * build-attempt loop and error message are unaffected.
 *
 * Streaming (a) lifts the output cap safely to 60K — the old 16K cap
 * existed only to stay under non-streaming HTTP timeouts and truncated half
 * of all flash generations — and (b) lets us surface per-file progress
 * while the model writes.
 */
async function callModelWithRetries(params: {
  model: LanguageModel;
  modelId: string;
  systemPrompt: string;
  conversation: ModelMessage[];
  attempt: number;
  onProgress?: (message: string) => void;
  onEvent?: (event: GenerateAttemptEvent) => void;
}): Promise<{
  generated: z.infer<typeof generatedTwistSchema>;
  usage: Extract<GenerateAttemptEvent, { type: "llm_complete" }>["usage"];
}> {
  const { model, modelId, systemPrompt, conversation, attempt, onProgress, onEvent } = params;
  let transientRetries = 0;
  let outputRetries = 0;
  // Declared outside the try so the catch block can read the stream's
  // finishReason to enrich NoOutputGeneratedError (which carries none of
  // its own) — see the enrichment below.
  let stream: ReturnType<typeof streamText> | undefined;
  for (;;) {
    try {
      // streamText returns synchronously; results arrive via streams/promises.
      stream = streamText({
        model,
        maxOutputTokens: 60_000,
        output: Output.object({
          schema: generatedTwistSchema,
          name: "TwistSource",
          description:
            'Twist source code: a files array (each entry has a path like "index.ts" and the full file content) plus an npm dependencies array (name + version).',
        }),
        instructions: modelId.startsWith("claude")
          ? {
              role: "system",
              content: systemPrompt,
              providerOptions: {
                anthropic: { cacheControl: { type: "ephemeral" } },
              },
            }
          : systemPrompt,
        // Snapshot, not the live reference: `conversation` is mutated in
        // place (assistant/error/corrective turns pushed) after this call
        // returns, both by later build attempts and by the retry loop
        // below within this same call. Passing the reference would let
        // those later pushes retroactively "rewrite" what earlier calls
        // appear to have sent.
        messages: [...conversation],
      });

      // Announce each file path once as it appears in the partial output.
      // Per-attempt (not deduped across attempts): each retry regenerates
      // everything, so announcing files again is honest progress.
      const announced = new Set<string>();
      for await (const partial of stream.partialOutputStream) {
        const files = (partial as { files?: Array<{ path?: string }> })?.files ?? [];
        for (const file of files) {
          if (file?.path && !announced.has(file.path)) {
            announced.add(file.path);
            onProgress?.(`Writing ${file.path}`);
          }
        }
      }

      const generated = await stream.output;
      const usage = extractUsage({
        usage: await stream.usage,
        providerMetadata: (await stream.finalStep).providerMetadata as
          | Record<string, Record<string, unknown>>
          | undefined,
      });
      return { generated, usage };
    } catch (error) {
      // ai@7's NoOutputGeneratedError carries only {message, cause} — no
      // finishReason — under streamText+Output, unlike the non-streaming
      // NoObjectGeneratedError. Without this, the eval classifier can't
      // distinguish output_truncated from schema_mismatch. The stream's own
      // finishReason promise can itself reject; guard it.
      if (
        stream &&
        isOutputProblemError(error) &&
        (error as { finishReason?: string }).finishReason === undefined
      ) {
        const finishReason = await Promise.resolve(stream.finishReason).catch(
          () => undefined
        );
        if (finishReason !== undefined) {
          (error as { finishReason?: string }).finishReason = finishReason;
        }
      }
      if (isTransientLlmError(error) && transientRetries < TRANSIENT_MAX_RETRIES) {
        const backoff = TRANSIENT_BACKOFF_MS[transientRetries];
        transientRetries++;
        safeEmit(onEvent, { type: "llm_retry", attempt, reason: "transient", retry: transientRetries });
        await sleep(backoff * (0.5 + Math.random() * 0.5)); // full jitter
        continue;
      }
      if (isOutputProblemError(error) && outputRetries < OUTPUT_MAX_RETRIES) {
        outputRetries++;
        safeEmit(onEvent, { type: "llm_retry", attempt, reason: "output", retry: outputRetries });
        conversation.push({
          role: "user",
          content:
            "The last generation attempt did not produce a valid twist object (it was truncated or failed schema validation). Generate the complete twist again, matching the schema exactly.",
        });
        continue;
      }
      throw error;
    }
  }
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

  // The conversation grows across build-repair attempts: the spec stays in
  // the first user turn, each attempt's output becomes an assistant turn,
  // and build errors arrive as user feedback turns. Retries therefore never
  // lose the original intent (they previously saw only the prior JSON).
  const conversation: ModelMessage[] = [
    {
      role: "user",
      content: `Generate a Plot twist based on this specification:

${spec}

Requirements:
- "displayName" must be a concise, human-readable title for the twist (e.g., "Google Calendar Sync", "Task Manager")
- Extract the displayName from the specification based on the twist's purpose
- "files" must include an entry whose path is "index.ts" — the entry point
- The index.ts file must export a default class extending Twist
`,
    },
  ];

  // Get complete SDK type definitions with import paths
  const sdkDocs = getBuilderDocumentation();

  // System prompt structured for optimal prompt caching:
  // 1. SDK type definitions (largest, most static) - FIRST for best caching
  // 2. TWIST_GUIDE (large, static) - SECOND for caching
  // 3. Instructions (small, static) - THIRD
  // Variable content (spec, errors) goes in the conversation to preserve cache.
  // Loop-invariant: computed once, reused by every attempt.
  const systemPrompt = `You are an expert at generating Plot twists.

${sdkDocs}

${TWIST_GUIDE}`;

  while (attempt < MAX_ATTEMPTS) {
    attempt++;
    onAttempt(attempt);
    safeEmit(onEvent, { type: "attempt_start", attempt });

    // Report progress
    onProgress?.(
      attempt === 1 ? "Generating twist code" : "Adjusting twist code"
    );

    // Call the model (Gemini by default, Claude via override) through the
    // Cloudflare AI Gateway, retrying transient/output-problem failures
    // within budget before surfacing them to this attempt loop.
    const llmStart = Date.now();
    const { generated, usage } = await callModelWithRetries({
      model,
      modelId,
      systemPrompt,
      conversation,
      attempt,
      onProgress,
      onEvent,
    });
    safeEmit(onEvent, {
      type: "llm_complete",
      attempt,
      durationMs: Date.now() - llmStart,
      usage,
    });

    conversation.push({ role: "assistant", content: JSON.stringify(generated) });

    // Map the model's array-shaped response back into the Record-shaped
    // TwistSource. Zod already validated the array shape above.
    const source: TwistSource = toTwistSource(generated);
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

    // Build failed - feed the errors back as the next turn.
    conversation.push({
      role: "user",
      content: `The twist failed to build. Errors:\n\n${buildResult.errors.join("\n\n")}\n\nFix these and return the complete corrected twist.`,
    });

    const logger = createLogger();
    logger.warn("Twist build errors on attempt", {
      attempt,
      errors: buildResult.errors.join("\n\n"),
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
