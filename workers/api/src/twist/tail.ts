import { WorkerEntrypoint } from "cloudflare:workers";

import { type TwistEnvironment, type LogMessage } from "../env";
import { Usage } from "../state/usage";
import { createLogger } from "@plotday/worker-util";

/**
 * Tail handler for capturing console logs and usage metrics from dynamically loaded twist workers.
 * Twist metadata (twistRootId, environment) is passed as trusted props from the API worker.
 * twistInstanceId is extracted from per-invocation context logs to support worker sharing across
 * multiple twist_instance instances.
 */
export class TwistTail extends WorkerEntrypoint<
  {
    TWIST_LOGS_QUEUE: Queue<LogMessage>;
    USAGE: DurableObjectNamespace<Usage>;
  },
  {
    twistRootId: string;
    environment: TwistEnvironment;
  }
> {
  async tail(events: TraceItem[]): Promise<void> {
    const logMessages: LogMessage[] = [];

    // Get trusted metadata from props (passed from API worker)
    const { twistRootId, environment } = this.ctx.props;

    // Track Workers usage metrics per twistInstanceId
    // Map of twistInstanceId -> { invocations, cpuTimeMs }
    const usageByTwistInstance = new Map<
      string,
      { invocations: number; cpuTimeMs: number }
    >();

    for (const event of events) {
      // Extract twistInstanceId from context logs
      let twistInstanceId: string | undefined;
      for (const logEntry of event.logs || []) {
        const message = logEntry.message
          .map((msg: any) => (typeof msg === "string" ? msg : String(msg)))
          .join(" ");

        // Parse context log: [TWIST_CONTEXT] twistInstanceId=<id>
        const contextMatch = message.match(/^\[TWIST_CONTEXT\] twistInstanceId=(.+)$/);
        if (contextMatch) {
          twistInstanceId = contextMatch[1];
          break; // Found context, stop looking
        }
      }

      // Skip deployment operations (permission collection) and malformed events
      if (!twistInstanceId || twistInstanceId === "__deployment__") {
        continue;
      }

      // Initialize usage tracking for this twistInstanceId if needed
      if (!usageByTwistInstance.has(twistInstanceId)) {
        usageByTwistInstance.set(twistInstanceId, {
          invocations: 0,
          cpuTimeMs: 0,
        });
      }
      const usageMetrics = usageByTwistInstance.get(twistInstanceId)!;

      // Track worker invocations (1 per event)
      usageMetrics.invocations++;

      // Track CPU time in milliseconds
      usageMetrics.cpuTimeMs += event.cpuTime;

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

          // Skip TWIST_CONTEXT logs (internal metadata, not user-facing)
          if (message.startsWith("[TWIST_CONTEXT]")) {
            continue;
          }

          // Skip RPC stub disposal warnings (framework noise, not twist code)
          if (message.includes("An RPC stub was not disposed properly")) {
            continue;
          }

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
            twistRootId,
            environment,
            severity,
            message,
            timestamp: logEntry.timestamp || Date.now(),
          });
        }
      }

      // Process diagnosticsChannelEvents for AI usage tracking
      if (event.diagnosticsChannelEvents) {
        // Get usage instance for this twistInstanceId
        const usage = Usage.Get(this.env, twistInstanceId);

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
              const logger = createLogger({
                twist_root_id: twistRootId,
                environment,
                twist_instance_id: twistInstanceId,
              });
              logger.error(
                "Failed to parse AI usage from diagnostics",
                error as Error
              );
            }
          }
        }
      }
    }

    // Record Workers usage metrics per twistInstanceId
    for (const [twistInstanceId, metrics] of usageByTwistInstance.entries()) {
      const usage = Usage.Get(this.env, twistInstanceId);

      if (metrics.invocations > 0) {
        usage.spend("worker:invocation", metrics.invocations);
      }
      if (metrics.cpuTimeMs > 0) {
        usage.spend("worker:cpu_ms", metrics.cpuTimeMs);
      }
    }

    // Send logs to queue if we have any
    // Cloudflare Queues has a limit of 100 messages per batch
    if (logMessages.length > 0) {
      const BATCH_SIZE = 100;
      const batches: MessageSendRequest<LogMessage>[][] = [];

      for (let i = 0; i < logMessages.length; i += BATCH_SIZE) {
        const chunk = logMessages.slice(i, i + BATCH_SIZE);
        batches.push(chunk.map((msg) => ({ body: msg })));
      }

      // Send all batches in parallel
      await Promise.all(
        batches.map((batch) => this.env.TWIST_LOGS_QUEUE.sendBatch(batch))
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
