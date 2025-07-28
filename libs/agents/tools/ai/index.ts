export interface Ai {
  promptLlm(
    messages: LlmMessage[],
    options?: { schema?: object }
  ): Promise<any>;
}

export type LlmMessage = {
  role: "user" | "assistant" | "system";
  content: string;
};
