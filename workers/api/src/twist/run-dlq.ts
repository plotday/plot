import { createLogger } from "@plotday/worker-util";

import { extractRunQueueContext } from "../utils/log-context";
import type { RunMessage } from "./tools/tasks";

/**
 * Dead-letter consumer for RUN_QUEUE. A scheduled task message lands here only
 * after exhausting its retries (e.g. a transient DB/Hyperdrive storm). Without
 * this, the message was silently dropped and — for recurring chains — the next
 * occurrence would be lost. Recurring tasks now self-heal (the DO alarm re-arms
 * the next beat), so this consumer's job is OBSERVABILITY: surface the drop so a
 * persistent failure isn't invisible. Terminal: always ack.
 *
 * The drop is recorded via a structured `logger.error` only — this handler
 * deliberately does NOT `captureException` to PostHog Error Tracking. By the
 * time a message reaches the DLQ its cause was already handled upstream:
 *   - A real bug took processQueue's `failure_retry` path, which captures the
 *     actual error WITH full context (twist, path, attempts) on every attempt —
 *     so a second capture here is redundant noise.
 *   - A rate-limit / transient exhaustion is an expected, self-resolving
 *     condition we intentionally don't page on (see isRateLimitError /
 *     isTransientError in tasks.ts).
 * The DLQ message carries no error to classify, so the old capture could only
 * emit a generic `RUN_QUEUE dead-letter: <path>` — empty for a connector's own
 * recurring poll (`path === []`) — which collapsed every unrelated drop into a
 * single uninformative catch-all issue (PostHog 019ed581). Per AGENTS.md we
 * capture unexpected bugs, not expected/handled conditions; the structured log
 * keeps the drop queryable without polluting Error Tracking.
 */
export async function handleRunDlq(
  batch: MessageBatch<RunMessage>
): Promise<void> {
  for (const message of batch.messages) {
    const context = extractRunQueueContext(message.body, batch.queue);
    const logger = createLogger({ ...context, attempts: message.attempts });
    logger.error(
      "RunMessage dead-lettered",
      new Error("RUN_QUEUE message exhausted retries"),
      { outcome: "dead_letter" }
    );
    message.ack();
  }
}
