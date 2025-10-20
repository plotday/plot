import { createAnthropic } from "@ai-sdk/anthropic";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { createOpenAI } from "@ai-sdk/openai";
import { Output, generateText, jsonSchema } from "ai";
import type { Static, TSchema } from "typebox";
import { createWorkersAI } from "workers-ai-provider";

import {
  AIModel,
  type AIRequest,
  type AIResponse,
  type AIToolSet,
  type AI as IAI,
  type ModelPreferences,
} from "@plotday/sdk/tools/ai";

import type { Bindings } from "../../env";
import { Tool } from "./tool";

export class AI extends Tool implements IAI {
  private openai: ReturnType<typeof createOpenAI>;
  private anthropic: ReturnType<typeof createAnthropic>;
  private google: ReturnType<typeof createGoogleGenerativeAI>;
  private workersai: ReturnType<typeof createWorkersAI>;

  constructor(env: Bindings) {
    super();

    const gatewayBaseUrl = `https://gateway.ai.cloudflare.com/v1/${env.AI_GATEWAY_ACCOUNT_ID}/${env.AI_GATEWAY_ID}`;
    const gatewayHeaders = {
      "cf-aig-authorization": `Bearer ${env.AI_GATEWAY_TOKEN}`,
    };

    // Initialize provider instances with AI Gateway
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

    // Workers AI doesn't go through the gateway, it uses the binding directly
    this.workersai = createWorkersAI({ binding: env.AI });
  }

  /**
   * Selects the best AI model based on speed and cost preferences.
   * Maps preference combinations to specific models optimized for those requirements.
   * Uses only Anthropic and Workers AI models by default.
   */
  private selectModel(preferences: ModelPreferences): AIModel {
    const { speed, cost, hint } = preferences;

    // Allow explicit model override via hint, but only for Workers AI and Anthropic
    if (hint) {
      const hintStr = hint.toLowerCase();
      if (
        hintStr.startsWith("anthropic/") ||
        (!hintStr.startsWith("openai/") && !hintStr.startsWith("google/"))
      ) {
        // Accept anthropic/ models and any model without a provider prefix (assumed to be Workers AI)
        return hint as AIModel;
      }
      // Ignore hints for other providers and fall through to preference-based selection
    }

    // Model selection matrix based on speed and cost preferences
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
        return AIModel.CLAUDE_37_SONNET;
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
        return AIModel.CLAUDE_37_SONNET;
      } else {
        // Anthropic: Best-in-class reasoning and problem-solving
        // Alternatives: GPT_5_PRO, GEMINI_25_PRO
        return AIModel.CLAUDE_SONNET_45;
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
      // Workers AI models
      model = this.workersai(`@cf/${modelStr}` as any);
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
      tools: transformedTools,
      experimental_output,
      toolChoice,
    });

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
}
