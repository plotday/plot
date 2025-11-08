import { PostHog } from "posthog-node";

import { type RunMessage, Tasks } from "../agent/tools/tasks";
import {
  type Bindings,
  type LogMessage,
  type QueueMessage,
  type UpdateMessage,
} from "../env";
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
  const postHog = new PostHog(env.POSTHOG_API_KEY, {
    host: env.POSTHOG_HOST,
    flushAt: 10,
    flushInterval: 10,
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
        await processUpdates(
          batch as MessageBatch<UpdateMessage>,
          env,
          ctx,
          postHog
        );
        break;

      case "agent-logs-development":
      case "agent-logs-production":
        await processLogs(batch as MessageBatch<LogMessage>, env, postHog);
        break;

      default:
        console.error(`Unknown queue: ${batch.queue}`, {
          queue: batch.queue,
          messageCount: batch.messages.length,
        });
    }
  } catch (error) {
    console.error(error);
    postHog.captureException(error, undefined, {
      queue: batch.queue,
    });
  } finally {
    ctx.waitUntil(postHog.shutdown());
  }
}
