import { WorkerEntrypoint } from "cloudflare:workers";

import { type AgentEnvironment, type LogMessage } from "../env";
import { Usage } from "../state/usage";

/**
 * Tail handler for capturing console logs and usage metrics from dynamically loaded agent workers.
 * Agent metadata (agentRootId, environment, priorityAgentId) is passed as trusted props from the
 * API worker, preventing malicious agent code from spoofing log metadata.
 */
export class AgentTail extends WorkerEntrypoint<
  {
    AGENT_LOGS_QUEUE: Queue<LogMessage>;
    USAGE: DurableObjectNamespace<Usage>;
  },
  {
    agentRootId: string;
    environment: AgentEnvironment;
    priorityAgentId: string;
  }
> {
  async tail(events: TraceItem[]): Promise<void> {
    const logMessages: LogMessage[] = [];

    // Get trusted metadata from props (passed from API worker)
    const { agentRootId, environment, priorityAgentId } = this.ctx.props;

    // Get Usage DurableObject instance for tracking metrics
    const usage = Usage.Get(this.env, priorityAgentId);

    // Track Workers usage metrics
    let totalInvocations = 0;
    let totalCpuTimeMs = 0;

    for (const event of events) {
      // Track worker invocations (1 per event)
      totalInvocations++;

      // Track CPU time in milliseconds
      totalCpuTimeMs += event.cpuTime;

      // Process logs
      if (event.logs && event.logs.length > 0) {
        for (const logEntry of event.logs) {
          // Format message from log entry
          const message = logEntry.message
            .map((msg: any) => {
              if (typeof msg === "string") {
                return msg;
              }
              try {
                return JSON.stringify(msg);
              } catch {
                return String(msg);
              }
            })
            .join(" ");

          // Map log level to severity
          let severity: "log" | "info" | "warn" | "error";
          switch (logEntry.level) {
            case "error":
              severity = "error";
              break;
            case "warn":
              severity = "warn";
              break;
            case "info":
              severity = "info";
              break;
            default:
              severity = "log";
          }

          logMessages.push({
            agentRootId,
            environment,
            severity,
            message,
            timestamp: logEntry.timestamp || Date.now(),
          });
        }
      }

      // Process diagnosticsChannelEvents for AI usage tracking
      if (event.diagnosticsChannelEvents) {
        for (const diagEvent of event.diagnosticsChannelEvents) {
          // AI Gateway sends usage data in diagnosticsChannelEvents
          // Look for AI-related events (typically from cloudflare:ai-gateway channel)
          if (
            diagEvent.channel === "cloudflare:ai-gateway" &&
            diagEvent.message
          ) {
            try {
              const aiUsage = diagEvent.message;

              // Extract model name and token usage
              // Format varies by provider, but typically includes:
              // - model: string (e.g., "claude-sonnet-4.5")
              // - usage: { input_tokens, output_tokens, reasoning_tokens }
              if (aiUsage.model && aiUsage.usage) {
                const modelName = this.normalizeModelName(aiUsage.model);

                // Track input tokens
                if (aiUsage.usage.input_tokens) {
                  usage.spend(
                    `ai:${modelName}:input`,
                    aiUsage.usage.input_tokens
                  );
                }

                // Track output tokens
                if (aiUsage.usage.output_tokens) {
                  usage.spend(
                    `ai:${modelName}:output`,
                    aiUsage.usage.output_tokens
                  );
                }

                // Track reasoning tokens (if present, e.g., for Claude Sonnet with extended thinking)
                if (aiUsage.usage.reasoning_tokens) {
                  usage.spend(
                    `ai:${modelName}:reasoning`,
                    aiUsage.usage.reasoning_tokens
                  );
                }
              }
            } catch (error) {
              // Log parsing errors but don't fail the tail handler
              console.error(
                "Failed to parse AI usage from diagnostics:",
                error
              );
            }
          }
        }
      }
    }

    // Record Workers usage metrics
    if (totalInvocations > 0) {
      usage.spend("worker:invocation", totalInvocations);
    }
    if (totalCpuTimeMs > 0) {
      usage.spend("worker:cpu_ms", totalCpuTimeMs);
    }

    // Send logs to queue if we have any
    if (logMessages.length > 0) {
      await this.env.AGENT_LOGS_QUEUE.sendBatch(
        logMessages.map((msg) => ({ body: msg }))
      );
    }
  }

  /**
   * Normalize model name to a consistent format for cost tracking
   * Examples:
   * - "@cf/meta/llama-3.2-1b-instruct" -> "llama-3.2-1b"
   * - "anthropic/claude-sonnet-4.5" -> "claude-sonnet-4.5"
   * - "claude-sonnet-4.5" -> "claude-sonnet-4.5"
   */
  private normalizeModelName(model: string): string {
    // Remove provider prefixes
    let normalized = model
      .replace(/^@cf\/[^/]+\//, "") // Remove Workers AI prefix
      .replace(/^anthropic\//, "") // Remove Anthropic prefix
      .replace(/^openai\//, "") // Remove OpenAI prefix
      .replace(/^google\//, ""); // Remove Google prefix

    // Remove common suffixes
    normalized = normalized
      .replace(/-instruct$/, "")
      .replace(/-chat$/, "")
      .replace(/-base$/, "");

    return normalized;
  }
}
