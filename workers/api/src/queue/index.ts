import { PostHog } from "posthog-node";

import { type RunMessage, Tasks } from "../twist/tools/tasks";
import {
  type Bindings,
  type LogMessage,
  type QueueMessage,
  type TwistBatchMessage,
} from "../env";
import { createLogger } from "@plotday/worker-util";
import { processLogs } from "./logs";
import { processUpdates } from "./updates";

/**
 * Queue consumer handler for run callbacks, updates, and logs
 */
export async function queue(
  batch: MessageBatch<QueueMessage>,
  env: Bindings,
  ctx: ExecutionContext
): Promise<void> {
  // Generate request ID for this queue batch (for trace correlation)
  const request_id = crypto.randomUUID();

  const postHog = new PostHog(env.POSTHOG_API_KEY, {
    host: env.POSTHOG_HOST,
    flushAt: 10,
    flushInterval: 10,
  });

  // Create logger with queue context
  const logger = createLogger({
    request_id,
    queue: batch.queue,
    batch_size: batch.messages.length,
  });

  try {
    // Use batch.queue to distinguish between queues
    switch (batch.queue) {
      case "run-development":
      case "run-production":
        await Tasks.processQueue(
          env,
          batch as MessageBatch<RunMessage>,
          postHog
        );
        break;

      case "updates-development":
      case "updates-production":
      case "updates-production-v2":
        await processUpdates(
          batch as MessageBatch<TwistBatchMessage>,
          env,
          ctx,
          postHog
        );
        break;

      case "twist-logs-development":
      case "twist-logs-production":
        await processLogs(batch as MessageBatch<LogMessage>, env, postHog);
        break;

      default:
        logger.error("Unknown queue", {
          queue: batch.queue,
          message_count: batch.messages.length,
        });
    }
  } catch (error) {
    logger.error("Error processing queue batch", error as Error, {
      queue: batch.queue,
    });
    postHog.captureException(error as Error, undefined, {
      request_id,
      queue: batch.queue,
      batch_size: batch.messages.length,
    });
  } finally {
    ctx.waitUntil(postHog.shutdown());
  }
}
