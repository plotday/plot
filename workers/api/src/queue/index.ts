import { PostHog } from "posthog-node";

import { type RunMessage, Tasks } from "../twist/tools/tasks";
import { handleRunDlq } from "../twist/run-dlq";
import {
  type Bindings,
  type ExtractMessage,
  type LogMessage,
  type QueueMessage,
  type TwistBatchMessage,
  type WebhookMessage,
} from "../env";
import { createLogger, exceptionFingerprintBeforeSend } from "@plotday/worker-util";
import { processExtractions } from "./extract";
import { processLogs } from "./logs";
import { processMail } from "./mail";
import { processUpdates } from "./updates";
import { processWebhooks } from "./webhook";
import { shedBatchIfHot } from "./shed";

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
    before_send: exceptionFingerprintBeforeSend,
  });

  // Create logger with queue context
  const logger = createLogger({
    request_id,
    queue: batch.queue,
    batch_size: batch.messages.length,
  });

  if (shedBatchIfHot(batch, postHog, batch.queue)) {
    logger.warn("deferred queue batch under DB pressure", { queue: batch.queue });
    ctx.waitUntil(postHog.shutdown());
    return;
  }

  try {
    // Use batch.queue to distinguish between queues
    switch (batch.queue) {
      case "run-dlq-development":
      case "run-dlq-production":
      case "run-dlq-test":
        await handleRunDlq(batch as MessageBatch<RunMessage>);
        break;

      case "run-development":
      case "run-production":
        await Tasks.processQueue(
          env,
          ctx,
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
        await processLogs(batch as MessageBatch<LogMessage>, env, ctx, postHog);
        break;

      case "mail-development":
        // In development, the API worker consumes the mail queue directly
        // because wrangler dev doesn't reliably route queues between workers.
        // In production, the separate mailer worker handles this.
        await processMail(batch as MessageBatch<any>, env, ctx);
        break;

      case "webhook-development":
      case "webhook-production":
        await processWebhooks(
          batch as MessageBatch<WebhookMessage>,
          env,
          ctx,
          postHog
        );
        break;

      case "extract-development":
      case "extract-production":
        await processExtractions(
          batch as MessageBatch<ExtractMessage>,
          env,
          ctx,
          postHog
        );
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
