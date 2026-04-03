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

/** Configuration for a single AI provider selected by the user. */
export type AiProviderConfig = {
  provider: "openai" | "anthropic" | "google" | "custom";
  apiKey: string;
  /** Custom provider only: base URL of the OpenAI-compatible endpoint */
  baseUrl?: string;
  /** Custom provider only: model name for fast/balanced tiers */
  fastModel?: string;
  /** Custom provider only: model name for capable tier */
  thinkingModel?: string;
};

/**
 * Provider fallback mapping per speed tier.
 * Used when a single standard provider is configured.
 */
const PROVIDER_MODEL_MAP: Record<
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

/** Sentinel value used when selectModel returns a custom model name */
const CUSTOM_MODEL_PREFIX = "__custom__/";

export class AI extends Tool implements IAI {
  static Permissions(_options?: AIOptions): ToolPermission[] {
    return [{ domain: "ai", entity: "prompt", flags: ["use"] }];
  }
  private openai!: ReturnType<typeof createOpenAI>;
  private anthropic!: ReturnType<typeof createAnthropic>;
  private google!: ReturnType<typeof createGoogleGenerativeAI>;
  private cloudflare: ReturnType<typeof createWorkersAI>;
  private workersAI: Bindings["AI"];
  private usage: DurableObjectStub<Usage>;
  /** The single configured provider, or null for Plot AI (gateway mode). */
  private providerConfig: AiProviderConfig | null = null;

  constructor({
    env,
    priorityTwistId,
    providerConfig,
  }: {
    env: Bindings;
    priorityTwistId: string;
    providerConfig?: AiProviderConfig;
  }) {
    super();

    if (providerConfig) {
      this.providerConfig = providerConfig;

      switch (providerConfig.provider) {
        case "openai":
          this.openai = createOpenAI({ apiKey: providerConfig.apiKey });
          break;
        case "anthropic":
          this.anthropic = createAnthropic({ apiKey: providerConfig.apiKey });
          break;
        case "google":
          this.google = createGoogleGenerativeAI({ apiKey: providerConfig.apiKey });
          break;
        case "custom":
          // Custom OpenAI-compatible endpoint
          this.openai = createOpenAI({
            apiKey: providerConfig.apiKey,
            baseURL: providerConfig.baseUrl,
          });
          break;
      }
    } else {
      // Plot AI mode: AI Gateway to all providers
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

    // Workers AI always available (used for embeddings regardless of provider config)
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
   * When a provider is configured, restricts to that provider.
   * Returns a custom model string prefixed with CUSTOM_MODEL_PREFIX for custom providers.
   */
  private selectModel(preferences: ModelPreferences): string {
    const { speed, cost, hint } = preferences;
    const config = this.providerConfig;

    // Handle model hints
    if (hint && Object.values(AIModel).includes(hint as AIModel)) {
      const hintModel = hint as AIModel;
      if (config) {
        const hintProvider = modelProvider(hintModel);
        // If hint matches configured provider, use it
        if (hintProvider === config.provider) {
          return hintModel;
        }
        // Otherwise fall through to tier-based selection for the configured provider
      } else {
        // Plot AI mode: any hint is valid
        return hintModel;
      }
    }

    // Custom provider: use user-configured model names
    if (config?.provider === "custom") {
      const tier = speed || "fast";
      if (tier === "capable") {
        return `${CUSTOM_MODEL_PREFIX}${config.thinkingModel}`;
      }
      return `${CUSTOM_MODEL_PREFIX}${config.fastModel}`;
    }

    // Standard BYOK provider: use the tier map for that provider
    if (config) {
      const tier = speed || "fast";
      const tierMap = PROVIDER_MODEL_MAP[tier] ?? PROVIDER_MODEL_MAP.fast;
      const model = tierMap[config.provider];
      if (model) return model;

      throw new Error(
        `No AI model available for provider '${config.provider}' at tier '${tier}'`
      );
    }

    // Plot AI mode: standard model selection matrix
    if (speed === "fast") {
      if (cost === "low") return AIModel.LLAMA_32_1B;
      if (cost === "medium") return AIModel.CLAUDE_HAIKU_45;
      return AIModel.CLAUDE_HAIKU_45;
    }

    if (speed === "balanced") {
      if (cost === "low") return AIModel.LLAMA_4_SCOUT_17B;
      if (cost === "medium") return AIModel.LLAMA_33_70B;
      return AIModel.CLAUDE_SONNET_46;
    }

    if (speed === "capable") {
      if (cost === "low") return AIModel.DEEPSEEK_R1_32B;
      if (cost === "medium") return AIModel.CLAUDE_SONNET_46;
      return AIModel.CLAUDE_SONNET_46;
    }

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
    const modelStr = this.selectModel(modelInput);

    // Determine which provider to use based on the model string
    let model: any;

    if (modelStr.startsWith(CUSTOM_MODEL_PREFIX)) {
      // Custom provider: use chat API (Responses API not supported by most compatible endpoints)
      const customModelName = modelStr.slice(CUSTOM_MODEL_PREFIX.length);
      model = this.openai.chat(customModelName);
    } else if (modelStr.startsWith("openai/")) {
      const modelName = modelStr.replace("openai/", "");
      model = this.openai(modelName);
    } else if (modelStr.startsWith("anthropic/")) {
      const modelName = modelStr.replace("anthropic/", "");
      model = this.anthropic(modelName);
    } else if (modelStr.startsWith("google/")) {
      const modelName = modelStr.replace("google/", "");
      model = this.google(modelName);
    } else {
      // Workers AI models — disallowed when a provider is configured
      if (this.providerConfig) {
        throw new Error(
          `Provider '${this.providerConfig.provider}' is configured but model resolved to Workers AI (${modelStr}).`
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

    await this.trackUsage(modelStr, result.usage);

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
  private async trackUsage(model: string, usage: AIUsage) {
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
