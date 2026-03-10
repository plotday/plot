import { createAnthropic } from "@ai-sdk/anthropic";
import { generateObject } from "ai";
import { z } from "zod";

import { getBuilderDocumentation } from "@plotday/twister/creator-docs";
import { TWIST_GUIDE } from "@plotday/twister/twist-guide";

import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import { buildTwist } from "./builder";
import type { TwistSource } from "./types";

/**
 * Zod schema for validating TwistSource structure
 */
const twistSourceSchema = z.object({
  displayName: z.string(),
  files: z.record(z.string(), z.string()),
  dependencies: z.record(z.string(), z.string()),
});

export interface GenerateTwistOptions {
  spec: string;
  env: Bindings;
  onProgress?: (message: string) => void;
}

/**
 * Generates a twist source from a specification using Claude AI.
 *
 * This function uses an iterative approach with error correction:
 * 1. Generate source from spec using Claude
 * 2. Validate by building in sandbox
 * 3. If build errors, provide feedback to Claude and retry
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
}: GenerateTwistOptions): Promise<TwistSource> {
  if (
    !env.AI_GATEWAY_ACCOUNT_ID ||
    !env.AI_GATEWAY_ID ||
    !env.AI_GATEWAY_TOKEN
  ) {
    throw new Error("AI Gateway configuration is missing");
  }

  // Configure Anthropic provider with AI Gateway
  const gatewayBaseUrl = `https://gateway.ai.cloudflare.com/v1/${env.AI_GATEWAY_ACCOUNT_ID}/${env.AI_GATEWAY_ID}`;
  const anthropicProvider = createAnthropic({
    baseURL: `${gatewayBaseUrl}/anthropic`,
    apiKey: env.ANTHROPIC_API_KEY,
    headers: {
      "cf-aig-authorization": `Bearer ${env.AI_GATEWAY_TOKEN}`,
    },
  });

  const MAX_ATTEMPTS = 3;
  let attempt = 0;
  let previousSource: TwistSource | null = null;
  let previousErrors: string[] | null = null;

  while (attempt < MAX_ATTEMPTS) {
    attempt++;

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
- "files" must include "index.ts" as the entry point
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

    // Call Claude API via Vercel AI SDK and Cloudflare AI Gateway
    const model: any = anthropicProvider("claude-sonnet-4-5");
    const result = await generateObject({
      model,
      schema: twistSourceSchema,
      schemaName: "TwistSource",
      schemaDescription:
        "Twist source code structure containing source files and npm dependencies",
      maxOutputTokens: 4095,
      system: systemPrompt,
      prompt: userPrompt,
    });

    // Get the validated object from the result
    // Schema validation ensures dependencies and files exist
    const source: TwistSource = result.object;
    source.dependencies = {
      ...source.dependencies,
      "@plotday/twister": "latest",
    };

    // Validate required index.ts file exists
    if (!source.files["index.ts"]) {
      throw new Error("Generated connector is missing required 'index.ts' file");
    }

    // Try to build the twist
    const buildResult = await buildTwist(source, env, onProgress);

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
