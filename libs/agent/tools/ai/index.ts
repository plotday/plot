import { type BuiltInTool } from "../../sdk";

/**
 * Built-in tool for interacting with Large Language Models (LLMs).
 *
 * The AI tool provides agents and tools with access to LLM capabilities
 * for natural language processing, text generation, data extraction,
 * and intelligent decision making within their workflows.
 *
 * **Features:**
 * - Multi-turn conversation support
 * - Structured output with JSON schema validation
 * - System message support for context setting
 * - Automatic response parsing and validation
 *
 * @example
 * ```typescript
 * class SmartEmailTool extends Tool {
 *   private ai: Ai;
 *
 *   constructor(tools: Tools) {
 *     super();
 *     this.ai = tools.get<Ai>("ai");
 *   }
 *
 *   async categorizeEmail(emailContent: string) {
 *     const messages: LlmMessage[] = [
 *       {
 *         role: "system",
 *         content: "Classify emails into categories: work, personal, spam, or promotional."
 *       },
 *       {
 *         role: "user",
 *         content: `Categorize this email: ${emailContent}`
 *       }
 *     ];
 *
 *     const schema = {
 *       type: "object",
 *       properties: {
 *         category: { type: "string", enum: ["work", "personal", "spam", "promotional"] },
 *         confidence: { type: "number", minimum: 0, maximum: 1 },
 *         reasoning: { type: "string" }
 *       },
 *       required: ["category", "confidence"]
 *     };
 *
 *     return await this.ai.promptLlm(messages, { schema });
 *   }
 *
 *   async generateResponse(emailContent: string) {
 *     const messages: LlmMessage[] = [
 *       {
 *         role: "system",
 *         content: "Generate professional email responses that are helpful and concise."
 *       },
 *       {
 *         role: "user",
 *         content: `Write a response to: ${emailContent}`
 *       }
 *     ];
 *
 *     const response = await this.ai.promptLlm(messages);
 *     return response.content;
 *   }
 * }
 * ```
 */
export interface Ai extends BuiltInTool {
  /**
   * Sends a conversation to an LLM and returns the response.
   *
   * Supports multi-turn conversations with system, user, and assistant messages.
   * Optionally enforces structured output using JSON schema validation.
   *
   * @param messages - Array of conversation messages
   * @param options - Optional configuration
   * @param options.schema - JSON schema to enforce structured output format
   * @returns Promise resolving to the LLM response (parsed if schema provided)
   */
  promptLlm(
    messages: LlmMessage[],
    options?: { schema?: object }
  ): Promise<any>;
}

/**
 * Represents a single message in an LLM conversation.
 *
 * Messages form the conversation context that guides the LLM's response.
 * Different roles have different purposes in the conversation flow.
 *
 * @example
 * ```typescript
 * const conversation: LlmMessage[] = [
 *   {
 *     role: "system",
 *     content: "You are a helpful assistant that summarizes text."
 *   },
 *   {
 *     role: "user",
 *     content: "Summarize this article: [article text]"
 *   },
 *   {
 *     role: "assistant",
 *     content: "Here's a summary of the article: [summary]"
 *   },
 *   {
 *     role: "user",
 *     content: "Make it shorter."
 *   }
 * ];
 * ```
 */
export type LlmMessage = {
  /** The role determines the message's purpose in the conversation */
  role: "user" | "assistant" | "system";
  /** The text content of the message */
  content: string;
};
