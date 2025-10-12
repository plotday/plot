import type { Ai as IAi, LlmMessage } from "@plotday/sdk/tools/ai";

import { Tool } from "./tool";

export class AiTool extends Tool implements IAi {
  private ai: Ai;

  constructor({ ai }: { ai: Ai }) {
    super();
    this.ai = ai;
  }

  async promptLlm(
    messages: LlmMessage[],
    options?: { schema?: object }
  ): Promise<any> {
    const result = await this.ai.run(
      "@hf/meta-llama/meta-llama-3-8b-instruct",
      {
        messages,
        stream: false,
        max_tokens: 1024,
        ...(options?.schema && {
          response_format: {
            type: "json_schema",
            json_schema: options.schema,
          },
        }),
      }
    );
    return result;
  }
}
