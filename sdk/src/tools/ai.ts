import type { Static, TSchema } from "typebox";

import { ITool, type Tools } from "..";

/**
 * Built-in tool for prompting Large Language Models (LLMs).
 *
 * The AI tool provides agents and tools with access to LLM capabilities
 * for natural language processing, text generation, data extraction,
 * and intelligent decision making within their workflows.
 *
 * **Features:**
 * - Access to multiple AI providers (OpenAI, Anthropic, Google, Workers AI)
 * - Multi-turn conversation support with `messages`
 * - Tool calling with automatic execution
 * - Structured output with Typebox schemas via `outputSchema`
 * - Unified API across all models via Vercel AI SDK
 * - Automatic response parsing and validation with full type inference
 *
 * @example
 * ```typescript
 * import { Type } from "typebox";
 *
 * class SmartEmailTool extends Tool {
 *   private ai: AI;
 *
 *   constructor(tools: Tools) {
 *     super();
 *     this.ai = tools.get(AI);
 *   }
 *
 *   async categorizeEmail(emailContent: string) {
 *     // Define the output schema using Typebox
 *     const schema = Type.Object({
 *       category: Type.Union([
 *         Type.Literal("work"),
 *         Type.Literal("personal"),
 *         Type.Literal("spam"),
 *         Type.Literal("promotional")
 *       ]),
 *       confidence: Type.Number({ minimum: 0, maximum: 1 }),
 *       reasoning: Type.Optional(Type.String())
 *     });
 *
 *     const response = await this.ai.prompt({
 *       model: AIModel.GPT_4O_MINI,
 *       system: "Classify emails into categories: work, personal, spam, or promotional.",
 *       prompt: `Categorize this email: ${emailContent}`,
 *       outputSchema: schema
 *     });
 *
 *     return response.output;
 *   }
 *
 *   async generateResponse(emailContent: string) {
 *     const response = await this.ai.prompt({
 *       model: AIModel.GPT_4O_MINI,
 *       system: "Generate professional email responses that are helpful and concise.",
 *       prompt: `Write a response to: ${emailContent}`
 *     });
 *
 *     return response.text;
 *   }
 * }
 * ```
 */
export abstract class AI extends ITool {
  /**
   * Sends a request to an AI model and returns the response using the Vercel AI SDK.
   *
   * Supports text generation, multi-turn conversations, structured outputs,
   * and tool calling across multiple AI providers via Cloudflare AI Gateway.
   *
   * @param request - AI request with model, prompt/messages, and optional configuration
   * @returns Promise resolving to the AI response with generated text and metadata
   *
   * @example
   * ```typescript
   * // Simple text generation
   * const response = await ai.prompt({
   *   model: AIModel.GPT_4O_MINI,
   *   prompt: "Explain quantum computing in simple terms"
   * });
   * console.log(response.text);
   *
   * // With system instructions
   * const response = await ai.prompt({
   *   model: AIModel.CLAUDE_35_SONNET,
   *   system: "You are a helpful physics tutor.",
   *   prompt: "Explain quantum entanglement"
   * });
   * console.log(response.text);
   *
   * // Multi-turn conversation
   * const response = await ai.prompt({
   *   model: AIModel.CLAUDE_35_SONNET,
   *   messages: [
   *     { role: "user", content: "What is 2+2?" },
   *     { role: "assistant", content: "2+2 equals 4." },
   *     { role: "user", content: "What about 3+3?" }
   *   ]
   * });
   * console.log(response.text);
   *
   * // Structured output with Typebox schema
   * const response = await ai.prompt({
   *   model: AIModel.GPT_4O,
   *   prompt: "Extract information: John is 30 years old",
   *   outputSchema: Type.Object({
   *     name: Type.String(),
   *     age: Type.Number()
   *   })
   * });
   * console.log(response.output); // { name: "John", age: 30 }
   *
   * // Tool calling
   * const response = await ai.prompt({
   *   model: AIModel.GPT_4O_MINI,
   *   prompt: "What's the weather in San Francisco?",
   *   tools: {
   *     getWeather: {
   *       description: "Get weather for a city",
   *       parameters: Type.Object({
   *         city: Type.String()
   *       }),
   *       execute: async ({ city }) => {
   *         return { temp: 72, condition: "sunny" };
   *       }
   *     }
   *   }
   * });
   * console.log(response.text); // Model's response using tool results
   * console.log(response.toolCalls); // Array of tool calls made
   * ```
   */
  abstract prompt<TOOLS extends AIToolSet, SCHEMA extends TSchema = never>(
    _request: AIRequest<TOOLS, SCHEMA>,
  ): Promise<AIResponse<TOOLS, SCHEMA>>;
}

/**
 * Supported AI models available through Cloudflare AI Gateway and Workers AI.
 *
 * Models are organized by provider:
 * - **OpenAI**: Latest GPT models via AI Gateway
 * - **Anthropic**: Claude models via AI Gateway (prefix with "anthropic/")
 * - **Google**: Gemini models via AI Gateway (prefix with "google-ai-studio/")
 * - **Workers AI**: Models running on Cloudflare's network
 */
export enum AIModel {
  // OpenAI models
  GPT_4O = "openai/gpt-4o",
  GPT_4O_MINI = "openai/gpt-4o-mini",
  GPT_4_TURBO = "openai/gpt-4-turbo",
  GPT_35_TURBO = "openai/gpt-3.5-turbo",

  // Anthropic models
  CLAUDE_SONNET_4_5 = "anthropic/claude-sonnet-4-5",
  CLAUDE_35_SONNET = "anthropic/claude-3-5-sonnet",
  CLAUDE_3_OPUS = "anthropic/claude-3-opus",

  // Google models
  GEMINI_25_FLASH = "google/gemini-2.5-flash",

  // Cloudflare Workers AI models
  LLAMA_33_70B = "meta/llama-3.3-70b-instruct-fp8-fast",
  LLAMA_31_8B = "meta/llama-3.1-8b-instruct-fast",
  MISTRAL_7B = "meta/mistral-7b-instruct-v0.2",
}

/**
 * Request parameters for AI text generation, matching Vercel AI SDK's generateText() function.
 */
export interface AIRequest<
  TOOLS extends AIToolSet,
  SCHEMA extends TSchema = never,
> {
  /**
   * The AI model to use for generation.
   */
  model: AIModel;

  /**
   * System instructions to guide the model's behavior.
   */
  system?: string;

  /**
   * The user's input prompt. Can be a simple string or an array of messages for multi-turn conversations.
   */
  prompt?: string;

  /**
   * Conversation messages for multi-turn interactions.
   * Replaces 'prompt' for more complex conversations.
   */
  messages?: AIMessage[];

  /**
   * Tools that the model can call during generation.
   * Each tool definition includes a description, input schema, and optional execute function.
   */
  tools?: TOOLS;

  /**
   * Controls which tools the model can use.
   * - "auto": Model decides whether to use tools
   * - "none": Model cannot use tools
   * - "required": Model must use at least one tool
   * - { type: "tool", toolName: string }: Model must use specific tool
   */
  toolChoice?: ToolChoice<TOOLS>;

  /**
   * Structured output schema using Typebox.
   * Typebox schemas are JSON Schema objects that provide full TypeScript type inference.
   */
  outputSchema?: SCHEMA;

  /**
   * Maximum number of tokens to generate.
   */
  maxOutputTokens?: number;

  /**
   * Temperature for controlling randomness (0-2).
   * Higher values make output more random, lower values more deterministic.
   */
  temperature?: number;

  /**
   * Top P sampling parameter (0-1).
   * Controls diversity by limiting to top probability tokens.
   */
  topP?: number;
}

/**
 * Response from AI text generation, matching Vercel AI SDK's GenerateTextResult.
 */
export interface AIResponse<
  TOOLS extends AIToolSet,
  SCHEMA extends TSchema = never,
> {
  /**
   * The generated text.
   */
  text: string;

  /**
   * Tool calls made by the model during generation.
   */
  toolCalls?: ToolCallArray<TOOLS>;

  /**
   * Results from tool executions.
   */
  toolResults?: ToolResultArray<TOOLS>;

  /**
   * Reason why the model stopped generating.
   */
  finishReason:
    | "stop"
    | "length"
    | "content-filter"
    | "tool-calls"
    | "error"
    | "other"
    | "unknown";

  /**
   * Token usage information for this generation.
   */
  usage: AIUsage;

  /**
   * Sources used by the model (if supported).
   */
  sources?: Array<AISource>;

  /**
   * Structured output when using outputSchema.
   * Type is automatically inferred from the Typebox schema.
   */
  output?: Static<SCHEMA>;

  /**
   * Response metadata including messages.
   */
  response?: {
    id?: string;
    timestamp?: Date;
    modelId?: string;
    messages?: AIMessage[];
  };
}

// ============================================================================
// Message Types
// ============================================================================

/**
 * A system message. It can contain system information.
 *
 * Note: using the "system" part of the prompt is strongly preferred
 * to increase the resilience against prompt injection attacks,
 * and because not all providers support several system messages.
 */
export type AISystemMessage = {
  role: "system";
  content: string;
};

/**
 * A user message. It can contain text or a combination of text and images.
 */
export type AIUserMessage = {
  role: "user";
  content: string | Array<TextPart | ImagePart | FilePart>;
};

/**
 * An assistant message. It can contain text, tool calls, or a combination of text and tool calls.
 */
export type AIAssistantMessage = {
  role: "assistant";
  content:
    | string
    | Array<
        TextPart | FilePart | ReasoningPart | ToolCallPart | ToolResultPart
      >;
};

/**
 * A tool message. It contains the result of one or more tool calls.
 */
export type AIToolMessage = {
  role: "tool";
  content: Array<ToolResultPart>;
};

/**
 * A message that can be used in the `messages` field of a prompt.
 * It can be a user message, an assistant message, or a tool message.
 */
export type AIMessage =
  | AISystemMessage
  | AIUserMessage
  | AIAssistantMessage
  | AIToolMessage;

// ============================================================================
// Usage & Sources
// ============================================================================

/**
 * Represents the number of tokens used in a prompt and completion.
 */
export type AIUsage = {
  /**
   * The number of tokens used in the prompt.
   */
  inputTokens?: number;
  /**
   * The number of tokens used in the completion.
   */
  outputTokens?: number;
  /**
   * The total number of tokens used (promptTokens + completionTokens).
   */
  totalTokens?: number;
  /**
   * The number of reasoning tokens used in the completion.
   */
  reasoningTokens?: number;
};

/**
 * A source that has been used as input to generate the response.
 */
export type AISource =
  | {
      type: "source";
      /**
       * A URL source. This is returned by web search RAG models.
       */
      sourceType: "url";
      /**
       * The ID of the source.
       */
      id: string;
      /**
       * The URL of the source.
       */
      url: string;
      /**
       * The title of the source.
       */
      title?: string;
    }
  | {
      type: "source";
      /**
       * The type of source - document sources reference files/documents.
       */
      sourceType: "document";
      /**
       * The ID of the source.
       */
      id: string;
      /**
       * IANA media type of the document (e.g., 'application/pdf').
       */
      mediaType: string;
      /**
       * The title of the document.
       */
      title: string;
      /**
       * Optional filename of the document.
       */
      filename?: string;
    };

// ============================================================================
// Content Parts
// ============================================================================

/**
 * Text content part of a prompt. It contains a string of text.
 */
export interface TextPart {
  type: "text";
  /**
   * The text content.
   */
  text: string;
}

/**
 * Data content. Can either be a base64-encoded string, a Uint8Array, an ArrayBuffer, or a Buffer.
 */
export type DataContent = string | Uint8Array | ArrayBuffer | Buffer;

/**
 * Image content part of a prompt. It contains an image.
 */
export interface ImagePart {
  type: "image";
  /**
   * Image data. Can either be:
   *
   * - data: a base64-encoded string, a Uint8Array, an ArrayBuffer, or a Buffer
   * - URL: a URL that points to the image
   */
  image: DataContent | URL;
  /**
   * Optional mime type of the image.
   */
  mimeType?: string;
}

/**
 * File content part of a prompt. It contains a file.
 */
export interface FilePart {
  type: "file";
  /**
   * File data. Can either be:
   *
   * - data: a base64-encoded string, a Uint8Array, an ArrayBuffer, or a Buffer
   * - URL: a URL that points to the file
   */
  data: DataContent | URL;
  /**
   * Optional filename of the file.
   */
  filename?: string;
  /**
   * IANA media type of the file.
   *
   * @see https://www.iana.org/assignments/media-types/media-types.xhtml
   */
  mediaType: string;
}

/**
 * Reasoning content part of a prompt. It contains a reasoning.
 */
export interface ReasoningPart {
  type: "reasoning";
  /**
   * The reasoning text.
   */
  text: string;
  /**
   * An optional signature for verifying that the reasoning originated from the model.
   */
  signature?: string;
}

/**
 * Redacted reasoning content part of a prompt.
 */
export interface RedactedReasoningPart {
  type: "redacted-reasoning";
  /**
   * Redacted reasoning data.
   */
  data: string;
}

/**
 * Tool call content part of a prompt. It contains a tool call (usually generated by the AI model).
 */
export interface ToolCallPart {
  type: "tool-call";
  /**
   * ID of the tool call. This ID is used to match the tool call with the tool result.
   */
  toolCallId: string;
  /**
   * Name of the tool that is being called.
   */
  toolName: string;
  /**
   * Arguments of the tool call. This is a JSON-serializable object that matches the tool's input schema.
   */
  input: unknown;
}

type JSONValue = null | string | number | boolean | JSONObject | JSONArray;
type JSONObject = {
  [key: string]: JSONValue;
};
type JSONArray = JSONValue[];

/**
 * Tool result content part of a prompt. It contains the result of the tool call with the matching ID.
 */
export interface ToolResultPart {
  type: "tool-result";
  /**
   * ID of the tool call that this result is associated with.
   */
  toolCallId: string;
  /**
   * Name of the tool that generated this result.
   */
  toolName: string;
  /**
   * Result of the tool call. This is a JSON-serializable object.
   */
  output:
    | {
        type: "text";
        value: string;
      }
    | {
        type: "json";
        value: JSONValue;
      }
    | {
        type: "error-text";
        value: string;
      }
    | {
        type: "error-json";
        value: JSONValue;
      }
    | {
        type: "content";
        value: Array<
          | {
              type: "text";
              /**
Text content.
*/
              text: string;
            }
          | {
              type: "media";
              /**
Base-64 encoded media data.
*/
              data: string;
              /**
IANA media type.
@see https://www.iana.org/assignments/media-types/media-types.xhtml
*/
              mediaType: string;
            }
        >;
      };
}

// ============================================================================
// Tool Types
// ============================================================================

type ToolParameters = TSchema;

type inferParameters<PARAMETERS extends ToolParameters> = Static<PARAMETERS>;

/**
 * Options passed to tool execution functions.
 */
export interface ToolExecutionOptions {
  /**
   * The ID of the tool call. You can use it e.g. when sending tool-call related information with stream data.
   */
  toolCallId: string;
  /**
   * Messages that were sent to the language model to initiate the response that contained the tool call.
   * The messages **do not** include the system prompt nor the assistant response that contained the tool call.
   */
  messages: AIMessage[];
  /**
   * An optional abort signal that indicates that the overall operation should be aborted.
   */
  abortSignal?: AbortSignal;
}

/**
 * A tool contains the description and the schema of the input that the tool expects.
 * This enables the language model to generate the input.
 *
 * The tool can also contain an optional execute function for the actual execution function of the tool.
 */
export type AITool<PARAMETERS extends ToolParameters = any, RESULT = any> = {
  /**
   * The schema of the input that the tool expects. The language model will use this to generate the input.
   * It is also used to validate the output of the language model.
   * Use descriptions to make the input understandable for the language model.
   */
  parameters: PARAMETERS;
  /**
   * The schema of the input that the tool expects. The language model will use this to generate the input.
   * It is also used to validate the output of the language model.
   * Use descriptions to make the input understandable for the language model.
   */
  inputSchema: TSchema;
  /**
   * An optional description of what the tool does.
   * Will be used by the language model to decide whether to use the tool.
   * Not used for provider-defined tools.
   */
  description?: string;
  /**
   * An async function that is called with the arguments from the tool call and produces a result.
   * If not provided, the tool will not be executed automatically.
   *
   * @param args - The input of the tool call
   * @param options - Execution options including abort signal and messages
   */
  execute?: (
    args: inferParameters<PARAMETERS>,
    options: ToolExecutionOptions,
  ) => PromiseLike<RESULT>;
} & (
  | {
      /**
       * Function tool.
       */
      type?: undefined | "function";
    }
  | {
      /**
       * Provider-defined tool.
       */
      type: "provider-defined";
      /**
       * The ID of the tool. Should follow the format `<provider-name>.<tool-name>`.
       */
      id: `${string}.${string}`;
      /**
       * The arguments for configuring the tool. Must match the expected arguments defined by the provider for this tool.
       */
      args: Record<string, unknown>;
    }
);

/**
 * Tool choice for the generation. It supports the following settings:
 *
 * - `auto` (default): the model can choose whether and which tools to call.
 * - `required`: the model must call a tool. It can choose which tool to call.
 * - `none`: the model must not call tools
 * - `{ type: 'tool', toolName: string (typed) }`: the model must call the specified tool
 */
type ToolChoice<TOOLS extends Record<string, unknown>> =
  | "auto"
  | "none"
  | "required"
  | {
      type: "tool";
      toolName: Extract<keyof TOOLS, string>;
    };

export type AIToolSet = Record<
  string,
  (
    | AITool<never, never>
    | AITool<any, any>
    | AITool<any, never>
    | AITool<never, any>
  ) &
    Pick<AITool<any, any>, "execute">
>;

// ============================================================================
// Internal Helper Types
// ============================================================================

type ToolCallUnion<_TOOLS extends AIToolSet> = {
  type: "tool-call";
  toolCallId: string;
  toolName: string;
  args?: unknown;
};

type ToolCallArray<TOOLS extends AIToolSet> = Array<ToolCallUnion<TOOLS>>;

type ToolResultUnion<_TOOLS extends AIToolSet> = {
  type: "tool-result";
  toolCallId: string;
  toolName: string;
  args?: unknown;
  result?: unknown;
};

type ToolResultArray<TOOLS extends AIToolSet> = Array<ToolResultUnion<TOOLS>>;
