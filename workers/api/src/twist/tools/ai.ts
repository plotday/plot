import { createAnthropic } from "@ai-sdk/anthropic";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { createOpenAI } from "@ai-sdk/openai";
import { Output, generateText, jsonSchema } from "ai";
import type { Static, TSchema } from "typebox";
import { createWorkersAI } from "workers-ai-provider";

import {
  AIModel,
  type AICapabilities,
  type AIOptions,
  type AIRequest,
  type AIResponse,
  type AIToolSet,
  type AIUsage,
  type AI as IAI,
  type ModelPreferences,
} from "@plotday/twister/tools/ai";

import type { Bindings } from "../../env";
import { Usage } from "../../state/usage";
import type { ToolPermission } from "../permissions";
import { Tool } from "./tool";

export type ByokKeys = Partial<Record<"openai" | "anthropic" | "google", string>>;

/**
 * BYOK provider fallback mapping per speed tier.
 * When a user only has keys for certain providers, we pick the best
 * model from their available providers at each tier.
 */
const BYOK_MODEL_MAP: Record<
  string,
  Record<string, AIModel>
> = {
  fast: {
    openai: AIModel.GPT_5_MINI,
    anthropic: AIModel.CLAUDE_HAIKU_45,
    google: AIModel.GEMINI_25_FLASH_LITE,
  },
  balanced: {
    openai: AIModel.GPT_5_MINI,
    anthropic: AIModel.CLAUDE_SONNET_46,
    google: AIModel.GEMINI_25_FLASH,
  },
  capable: {
    openai: AIModel.GPT_5,
    anthropic: AIModel.CLAUDE_SONNET_46,
    google: AIModel.GEMINI_25_PRO,
  },
};

/** Extract the provider prefix from a model enum value */
function modelProvider(model: AIModel): string | null {
  const str = model as string;
  if (str.startsWith("openai/")) return "openai";
  if (str.startsWith("anthropic/")) return "anthropic";
  if (str.startsWith("google/")) return "google";
  return null; // Workers AI model
}

export class AI extends Tool implements IAI {
  static Permissions(_options?: AIOptions): ToolPermission[] {
    return [{ domain: "ai", entity: "prompt", flags: ["use"] }];
  }
  private openai: ReturnType<typeof createOpenAI>;
  private anthropic: ReturnType<typeof createAnthropic>;
  private google: ReturnType<typeof createGoogleGenerativeAI>;
  private cloudflare: ReturnType<typeof createWorkersAI>;
  private workersAI: Bindings["AI"];
  private usage: DurableObjectStub<Usage>;
  /** When set, only these providers are available for prompt(). */
  private availableProviders: Set<string> | null = null;

  constructor({
    env,
    priorityTwistId,
    byokKeys,
  }: {
    env: Bindings;
    priorityTwistId: string;
    byokKeys?: ByokKeys;
  }) {
    super();

    const hasByok = byokKeys && Object.keys(byokKeys).length > 0;

    if (hasByok) {
      // BYOK mode: create provider instances with direct API keys (no AI Gateway)
      this.availableProviders = new Set(Object.keys(byokKeys));

      this.openai = createOpenAI({
        apiKey: byokKeys.openai ?? "unused",
      });
      this.anthropic = createAnthropic({
        apiKey: byokKeys.anthropic ?? "unused",
      });
      this.google = createGoogleGenerativeAI({
        apiKey: byokKeys.google ?? "unused",
      });
    } else {
      // Standard mode: AI Gateway
      const gatewayBaseUrl = `https://gateway.ai.cloudflare.com/v1/${env.AI_GATEWAY_ACCOUNT_ID}/${env.AI_GATEWAY_ID}`;
      const gatewayHeaders = {
        "cf-aig-authorization": `Bearer ${env.AI_GATEWAY_TOKEN}`,
      };

      this.openai = createOpenAI({
        baseURL: `${gatewayBaseUrl}/openai`,
        headers: gatewayHeaders,
      });

      this.anthropic = createAnthropic({
        baseURL: `${gatewayBaseUrl}/anthropic`,
        apiKey: env.ANTHROPIC_API_KEY,
        headers: gatewayHeaders,
      });

      this.google = createGoogleGenerativeAI({
        baseURL: `${gatewayBaseUrl}/google-ai-studio/v1beta`,
        headers: gatewayHeaders,
      });
    }

    // Workers AI always available (used for embeddings regardless of BYOK)
    this.cloudflare = createWorkersAI({ binding: env.AI });
    this.workersAI = env.AI;

    // Initialize usage tracking
    this.usage = Usage.Get(env, priorityTwistId);
  }

  available(): AICapabilities {
    return { prompt: true, embed: true };
  }

  /**
   * Selects the best AI model based on speed and cost preferences.
   * When BYOK is active, restricts to available providers.
   */
  private selectModel(preferences: ModelPreferences): AIModel {
    const { speed, cost, hint } = preferences;

    // Allow explicit model override via hint for any valid AIModel
    if (hint && Object.values(AIModel).includes(hint as AIModel)) {
      const hintModel = hint as AIModel;
      // If BYOK active, validate the hint model's provider is available
      if (this.availableProviders) {
        const provider = modelProvider(hintModel);
        if (!provider || !this.availableProviders.has(provider)) {
          // Hint unavailable, fall through to tier-based selection
        } else {
          return hintModel;
        }
      } else {
        return hintModel;
      }
    }

    // If BYOK is active, use the provider-restricted model map
    if (this.availableProviders) {
      const tier = speed || "fast";
      const tierMap = BYOK_MODEL_MAP[tier] ?? BYOK_MODEL_MAP.fast;

      // Find the first available provider in this tier
      for (const provider of this.availableProviders) {
        if (tierMap[provider]) {
          return tierMap[provider];
        }
      }

      throw new Error(
        `No AI model available for the requested preferences. Available providers: [${[...this.availableProviders].join(", ")}]`
      );
    }

    // Standard model selection matrix (no BYOK)
    // Fast tier: Optimized for low latency
    if (speed === "fast") {
      if (cost === "low") {
        // Workers AI: Free, very fast, 1B model
        return AIModel.LLAMA_32_1B;
      } else if (cost === "medium") {
        // Anthropic: Extremely fast with excellent quality
        // Alternatives: GPT_4O_MINI, GEMINI_25_FLASH_LITE
        return AIModel.CLAUDE_HAIKU_45;
      } else {
        // Anthropic: Premium fast model with best quality
        // Alternatives: GPT_4O_MINI, GEMINI_25_FLASH
        return AIModel.CLAUDE_HAIKU_45;
      }
    }

    // Balanced tier: Good mix of capability and speed
    if (speed === "balanced") {
      if (cost === "low") {
        // Workers AI: Free, 17B reasoning model
        return AIModel.LLAMA_4_SCOUT_17B;
      } else if (cost === "medium") {
        // Workers AI: Free, capable 70B model
        // Alternatives: GPT_5_MINI, GEMINI_25_FLASH
        return AIModel.LLAMA_33_70B;
      } else {
        // Anthropic: Hybrid reasoning model with fast responses and deeper thinking
        // Alternatives: GPT_5, GEMINI_25_FLASH
        return AIModel.CLAUDE_SONNET_46;
      }
    }

    // Capable tier: Maximum reasoning and problem-solving
    if (speed === "capable") {
      if (cost === "low") {
        // Workers AI: Free, 32B reasoning model (DeepSeek R1)
        return AIModel.DEEPSEEK_R1_32B;
      } else if (cost === "medium") {
        // Anthropic: Advanced reasoning with thinking mode
        // Alternatives: GEMINI_25_PRO, GPT_5_PRO
        return AIModel.CLAUDE_SONNET_46;
      } else {
        // Anthropic: Best-in-class reasoning and problem-solving
        // Alternatives: GPT_5_PRO, GEMINI_25_PRO
        return AIModel.CLAUDE_SONNET_46;
      }
    }

    // Default fallback: Fast, reliable, good quality
    // Alternatives: GPT_5_MINI, GEMINI_25_FLASH, LLAMA_33_70B
    return AIModel.CLAUDE_HAIKU_45;
  }

  async prompt<TOOLS extends AIToolSet, SCHEMA extends TSchema = never>(
    request: AIRequest<TOOLS, SCHEMA>
  ): Promise<AIResponse<TOOLS, SCHEMA>> {
    const {
      model: modelInput,
      system,
      prompt,
      messages,
      tools,
      outputSchema,
      maxOutputTokens,
      temperature,
      topP,
      toolChoice,
    } = request;

    // Determine the actual model to use from preferences
    const modelEnum = this.selectModel(modelInput);

    // Determine which provider to use based on the model enum value
    let model: any;
    const modelStr = modelEnum as string;

    if (modelStr.startsWith("openai/")) {
      // OpenAI models
      const modelName = modelStr.replace("openai/", "");
      model = this.openai(modelName);
    } else if (modelStr.startsWith("anthropic/")) {
      // Anthropic models
      const modelName = modelStr.replace("anthropic/", "");
      model = this.anthropic(modelName);
    } else if (modelStr.startsWith("google/")) {
      // Google models
      const modelName = modelStr.replace("google/", "");
      model = this.google(modelName);
    } else {
      // Workers AI models — disallowed when BYOK is active
      if (this.availableProviders) {
        throw new Error(
          `BYOK is active but model resolved to Workers AI (${modelStr}). ` +
            `Available providers: [${[...this.availableProviders].join(", ")}]`
        );
      }
      model = this.cloudflare(`@cf/${modelStr}` as any);
    }

    // Prepare experimental_output if outputSchema is provided
    // Typebox schemas ARE JSON Schema, so we wrap them with jsonSchema() helper
    let experimental_output = outputSchema
      ? Output.object({
          schema: jsonSchema<Static<SCHEMA>>(outputSchema),
        })
      : undefined;

    // Transform tools to AI SDK format
    // Convert Typebox schemas to jsonSchema format expected by AI SDK
    const transformedTools = tools
      ? Object.fromEntries(
          Object.entries(tools).map(([name, tool]) => [
            name,
            {
              description: tool.description,
              inputSchema: jsonSchema(tool.inputSchema),
              execute: tool.execute,
            },
          ])
        )
      : undefined;

    // Call generateText with the configured model and parameters
    // @ts-ignore - Type instantiation is excessively deep due to complex generic tool types
    const result = await generateText({
      model,
      maxOutputTokens,
      temperature,
      topP,
      system,
      ...(prompt ? { prompt: prompt! } : { messages: messages! }),
      tools: transformedTools as any,
      experimental_output,
      toolChoice,
    });

    await this.trackUsage(modelEnum, result.usage);

    return {
      text: result.text,
      toolCalls: result.toolCalls,
      toolResults: result.toolResults,
      finishReason: result.finishReason,
      usage: result.usage,
      sources: result.sources,
      output: experimental_output
        ? (result.experimental_output as Static<SCHEMA>)
        : undefined,
      // @ts-ignore - AI SDK ResponseMessage[] vs Twister AIMessage[] type mismatch due to duplicate type definitions
      response: result.response
        ? {
            id: result.response.id,
            timestamp: result.response.timestamp,
            modelId: result.response.modelId,
            messages: result.response.messages,
          }
        : undefined,
    };
  }

  /**
   * Generate embeddings for text using Cloudflare Workers AI.
   * Returns a 384-dimensional vector for semantic similarity search.
   *
   * Retries up to 2 times (3 total attempts) with a 3-second total timeout.
   *
   * @param text - The text to embed
   * @returns Promise resolving to a 384-dimension number array
   */
  async embed(text: string): Promise<number[]> {
    if (!text || text.trim().length === 0) {
      throw new Error("Cannot embed empty text");
    }

    const maxAttempts = 3;
    const totalTimeoutMs = 3000;
    const startTime = Date.now();
    let lastError: Error | undefined;

    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      // Check if we've exceeded the total timeout
      const elapsedTime = Date.now() - startTime;
      if (elapsedTime >= totalTimeoutMs) {
        throw new Error(
          `Embedding generation timed out after ${elapsedTime}ms (max: ${totalTimeoutMs}ms). Last error: ${lastError?.message || "unknown"}`
        );
      }

      try {
        // Use Workers AI binding directly for embeddings
        const response = (await this.workersAI.run(
          "@cf/baai/bge-small-en-v1.5",
          {
            text,
          }
        )) as { data: number[][] };

        // Response should contain the embedding array
        return response.data[0];
      } catch (error) {
        lastError = error instanceof Error ? error : new Error(String(error));

        // If this isn't the last attempt and we have time left, retry with a short delay
        if (attempt < maxAttempts) {
          const elapsedBeforeDelay = Date.now() - startTime;
          const remainingTime = totalTimeoutMs - elapsedBeforeDelay;

          if (remainingTime > 100) {
            // Only delay if we have at least 100ms left
            const delayMs = Math.min(100 * attempt, remainingTime - 50); // Exponential backoff, but leave some time
            await new Promise((resolve) => setTimeout(resolve, delayMs));
          }
        }
      }
    }

    // All attempts failed
    throw new Error(
      `Failed to generate embedding after ${maxAttempts} attempts: ${lastError?.message || "unknown error"}`
    );
  }

  /**
   * Track AI usage by recording token consumption
   */
  private async trackUsage(model: AIModel, usage: AIUsage) {
    if (!this.usage) return;

    if (usage.inputTokens) {
      this.usage.spend(`ai:${model}:input`, usage.inputTokens);
    }
    if (usage.outputTokens) {
      this.usage.spend(`ai:${model}:output`, usage.outputTokens);
    }
    if (usage.reasoningTokens) {
      this.usage.spend(`ai:${model}:reasoning`, usage.reasoningTokens);
    }
  }
}
