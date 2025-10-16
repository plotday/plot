import { createAnthropic } from "@ai-sdk/anthropic";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { createOpenAI } from "@ai-sdk/openai";
import { Output, generateText, jsonSchema } from "ai";
import type { Static, TSchema } from "typebox";
import { createWorkersAI } from "workers-ai-provider";

import type {
  AIRequest,
  AIResponse,
  AIToolSet,
  AI as IAI,
} from "../types/tools/ai";
import { Tool } from "./tool";

export class AI extends Tool implements IAI {
  private openai: ReturnType<typeof createOpenAI>;
  private anthropic: ReturnType<typeof createAnthropic>;
  private google: ReturnType<typeof createGoogleGenerativeAI>;
  private workersai: ReturnType<typeof createWorkersAI>;

  constructor({
    accountId,
    gatewayId,
    ai,
  }: {
    accountId: string;
    gatewayId: string;
    ai: Ai;
  }) {
    super();

    const gatewayBaseUrl = `https://gateway.ai.cloudflare.com/v1/${accountId}/${gatewayId}`;

    // Initialize provider instances with AI Gateway
    this.openai = createOpenAI({
      baseURL: `${gatewayBaseUrl}/openai`,
    });

    this.anthropic = createAnthropic({
      baseURL: `${gatewayBaseUrl}/anthropic`,
    });

    this.google = createGoogleGenerativeAI({
      baseURL: `${gatewayBaseUrl}/google-ai-studio/v1beta`,
    });

    // Workers AI doesn't go through the gateway, it uses the binding directly
    this.workersai = createWorkersAI({ binding: ai });
  }

  async prompt<TOOLS extends AIToolSet, SCHEMA extends TSchema = never>(
    request: AIRequest<TOOLS, SCHEMA>
  ): Promise<AIResponse<TOOLS, SCHEMA>> {
    const {
      model: modelEnum,
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
    let experimental_output;
    if (outputSchema) {
      experimental_output = Output.object({
        schema: jsonSchema<Static<SCHEMA>>(outputSchema),
      });
    }

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
      output: result.experimental_output as Static<SCHEMA> | undefined,
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
