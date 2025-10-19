import { createAnthropic } from "@ai-sdk/anthropic";
import { generateObject } from "ai";
import { z } from "zod";

import { AGENTS_GUIDE } from "@plotday/sdk/agents-guide";
import { getSDKDocumentation } from "@plotday/sdk/sdk-docs";

import type { Bindings } from "../env";
import { buildAgent } from "./builder";
import type { AgentSource } from "./types";

/**
 * Zod schema for validating AgentSource structure
 */
const agentSourceSchema = z.object({
  displayName: z.string(),
  files: z.record(z.string(), z.string()),
  dependencies: z.record(z.string(), z.string()),
});

/**
 * Generates an agent source from a specification using Claude AI.
 *
 * This function uses an iterative approach with error correction:
 * 1. Generate source from spec using Claude
 * 2. Validate by building in sandbox
 * 3. If build errors, provide feedback to Claude and retry
 * 4. Repeat up to 3 times
 * 5. Return valid source or throw error
 *
 * The system prompt is structured for optimal prompt caching:
 * - AGENTS_GUIDE (large, static) comes first for caching
 * - Role/instructions (small, static) follow
 * - Variable content (spec/errors) goes in the user prompt
 *
 * @param spec - Markdown specification describing the agent functionality
 * @param env - Bindings containing Sandbox
 * @returns Promise resolving to valid agent source
 * @throws Error if generation fails after max attempts
 */
export async function generateAgent(
  spec: string,
  env: Bindings
): Promise<AgentSource> {
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
  let previousSource: AgentSource | null = null;
  let previousErrors: string[] | null = null;

  while (attempt < MAX_ATTEMPTS) {
    attempt++;

    // Build the prompt based on whether this is a retry
    let userPrompt: string;

    if (attempt === 1) {
      // First attempt - just spec and guidance
      userPrompt = `Generate a Plot agent based on this specification:

${spec}

Requirements:
- "displayName" must be a concise, human-readable title for the agent (e.g., "Google Calendar Sync", "Task Manager")
- Extract the displayName from the specification based on the agent's purpose
- "files" must include "index.ts" as the entry point
- The index.ts file must export a default class extending Agent
`;
    } else {
      // Retry attempt - include previous attempt and errors
      userPrompt = `Your previous attempt to generate the agent had build errors.

Previous source you generated:
\`\`\`json
${JSON.stringify(previousSource, null, 2)}
\`\`\`

Build errors:
${previousErrors?.join("\n\n")}

Please fix these errors and generate a corrected version.`;
    }

    // Get complete SDK type definitions with import paths
    const sdkDocs = getSDKDocumentation();

    // System prompt structured for optimal prompt caching:
    // 1. SDK type definitions (largest, most static) - FIRST for best caching
    // 2. AGENTS_GUIDE (large, static) - SECOND for caching
    // 3. Instructions (small, static) - THIRD
    // Variable content (spec, errors) goes in user prompt to preserve cache
    const systemPrompt = `You are an expert at generating Plot agents.

${sdkDocs}

${AGENTS_GUIDE}`;

    // Call Claude API via Vercel AI SDK and Cloudflare AI Gateway
    const model: any = anthropicProvider("claude-sonnet-4-5");
    const result = await generateObject({
      model,
      schema: agentSourceSchema,
      schemaName: "AgentSource",
      schemaDescription:
        "Agent source code structure containing source files and npm dependencies",
      maxOutputTokens: 4095,
      system: systemPrompt,
      prompt: userPrompt,
    });

    // Get the validated object from the result
    // Schema validation ensures dependencies and files exist
    const source: AgentSource = result.object;
    source.dependencies = {
      ...source.dependencies,
      "@plotday/sdk": "latest",
    };

    // Validate required index.ts file exists
    if (!source.files["index.ts"]) {
      throw new Error("Generated source is missing required 'index.ts' file");
    }

    // Try to build the agent
    const buildResult = await buildAgent(source, env);

    if (buildResult.success) {
      // Success! Return the source
      return source;
    }

    // Build failed - store for retry
    previousSource = source;
    previousErrors = buildResult.errors;

    if (attempt === MAX_ATTEMPTS) {
      // Max attempts reached
      throw new Error(
        `Failed to generate valid agent after ${MAX_ATTEMPTS} attempts. Final errors:\n${buildResult.errors.join(
          "\n\n"
        )}`
      );
    }

    // Continue to next attempt
  }

  throw new Error("Unexpected: loop exited without returning or throwing");
}
