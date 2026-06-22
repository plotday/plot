import type { PostHog } from "posthog-node";
import { createLogger } from "@plotday/worker-util";

import type { Bindings } from "../env";
import { extractRunQueueContext } from "../utils/log-context";
import type { RunMessage } from "./tools/tasks";

/**
 * Dead-letter consumer for RUN_QUEUE. A scheduled task message lands here only
 * after exhausting its retries (e.g. a transient DB/Hyperdrive storm). Without
 * this, the message was silently dropped and — for recurring chains — the next
 * occurrence would be lost. Recurring tasks now self-heal (the DO alarm re-arms
 * the next beat), so this consumer's job is OBSERVABILITY: surface the drop so a
 * persistent failure isn't invisible. Terminal: always ack.
 */
export async function handleRunDlq(
  env: Bindings,
  batch: MessageBatch<RunMessage>,
  postHog: PostHog
): Promise<void> {
  for (const message of batch.messages) {
    const context = extractRunQueueContext(message.body, batch.queue);
    const logger = createLogger({ ...context, attempts: message.attempts });
    logger.error(
      "RunMessage dead-lettered",
      new Error("RUN_QUEUE message exhausted retries"),
      { outcome: "dead_letter" }
    );
    postHog.captureException(
      new Error(`RUN_QUEUE dead-letter: ${message.body.path?.join("/")}`),
      message.body.twistInstanceId,
      { twist_instance_id: message.body.twistInstanceId, queue: batch.queue }
    );
    message.ack();
  }
}
