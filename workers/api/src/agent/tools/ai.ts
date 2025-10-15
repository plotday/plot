import { createAnthropic } from "@ai-sdk/anthropic";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { createOpenAI } from "@ai-sdk/openai";
import { Output, generateText, jsonSchema } from "ai";
import type { Static, TSchema } from "typebox";
import { createWorkersAI } from "workers-ai-provider";

import type {
  AIRequest,
  AIResponse,
  AITool,
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

  async prompt<
    TOOLS extends Record<string, AITool>,
    SCHEMA extends TSchema = never
  >(request: AIRequest<TOOLS, SCHEMA>): Promise<AIResponse<TOOLS, SCHEMA>> {
    const {
      model: modelEnum,
      system,
      prompt,
      messages,
      tools,
      outputSchema,
      maxTokens,
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
    let experimentalOutput;
    if (outputSchema) {
      experimentalOutput = Output.object({
        schema: jsonSchema<Static<SCHEMA>>(outputSchema as any),
      });
    }

    // Call generateText with the configured model and parameters
    const result = await generateText({
      model,
      system,
      prompt,
      messages,
      tools,
      ...(experimentalOutput
        ? { experimental_output: experimentalOutput }
        : {}),
      maxTokens,
      temperature,
      topP,
      toolChoice,
    });

    // Return response matching AIResponse interface
    return {
      text: result.text,
      toolCalls: result.toolCalls as any,
      toolResults: result.toolResults as any,
      finishReason: result.finishReason,
      usage: result.usage,
      sources: result.sources,
      output: result.experimental_output as Static<SCHEMA> | undefined,
      response: result.response,
    };
  }
}
