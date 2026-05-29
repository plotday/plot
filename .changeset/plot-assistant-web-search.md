---
"@plotday/twister": minor
---

Added: `note.handler` Plot option for a single conversational mention handler (bypasses intent matching), `AIRequest.webSearch` for provider-native web search, `AIRequest.maxSteps` for agentic multi-step tool use, and `AICapabilities.webSearch`. `AITool.parameters` is now an optional deprecated alias for `inputSchema`. `AI.available()` return type widened to `AICapabilities | Promise<AICapabilities>` to reflect that it resolves asynchronously over RPC (await it).
