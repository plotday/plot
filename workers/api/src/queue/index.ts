import { Run, type RunMessage } from "../agent/tools/run";
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
  // Use batch.queue to distinguish between queues
  switch (batch.queue) {
    case "run-development":
    case "run-production":
      await Run.processQueue(env, batch as MessageBatch<RunMessage>);
      break;

    case "updates-development":
    case "updates-production":
      await processUpdates(batch as MessageBatch<UpdateMessage>, env, ctx);
      break;

    case "agent-logs-development":
    case "agent-logs-production":
      await processLogs(batch as MessageBatch<LogMessage>, env);
      break;

    default:
      console.error(`Unknown queue: ${batch.queue}`, {
        queue: batch.queue,
        messageCount: batch.messages.length,
      });
  }
}
