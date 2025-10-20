import { WorkerEntrypoint } from "cloudflare:workers";

import { type LogMessage } from "../env";

/**
 * Tail handler for capturing console logs from dynamically loaded agent workers.
 * Agent metadata (agentRootId, environment) is passed as trusted props from the
 * API worker, preventing malicious agent code from spoofing log metadata.
 */
export class AgentTail extends WorkerEntrypoint<
  {
    AGENT_LOGS_QUEUE: Queue<LogMessage>;
  },
  {
    agentRootId: string;
    environment: "personal" | "private" | "review" | "public";
  }
> {
  async tail(events: TraceItem[]): Promise<void> {
    const logMessages: LogMessage[] = [];

    // Get trusted metadata from props (passed from API worker)
    const { agentRootId, environment } = this.ctx.props;

    for (const event of events) {
      // Skip events without logs
      if (!event.logs || event.logs.length === 0) {
        continue;
      }

      // Process each log entry
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

    // Send logs to queue if we have any
    if (logMessages.length > 0) {
      await this.env.AGENT_LOGS_QUEUE.sendBatch(
        logMessages.map((msg) => ({ body: msg }))
      );
    }
  }
}
