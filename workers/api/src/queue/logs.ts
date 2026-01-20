import type { PostHog } from "posthog-node";

import type { Callback } from "@plotday/twister/tools/callbacks";

import { Callbacks } from "../twist/tools/callbacks";
import { addLogsNote } from "../twist/dev-activities";
import { type Bindings, type LogMessage } from "../env";
import { extractLogQueueContext } from "../utils/log-context";
import { createLogger } from "../utils/logger";
import { disposeRpc } from "../utils/rpc";

export async function processLogs(
  batch: MessageBatch<LogMessage>,
  env: Bindings,
  postHog: PostHog
): Promise<void> {
  // Group logs by twist_root_id
  const logsByTwist = new Map<string, LogMessage[]>();

  for (const message of batch.messages) {
    const { twistRootId } = message.body;
    if (!logsByTwist.has(twistRootId)) {
      logsByTwist.set(twistRootId, []);
    }
    logsByTwist.get(twistRootId)!.push(message.body);
  }

  // Process each twist's logs
  for (const [twistRootId, logs] of logsByTwist.entries()) {
    try {
      // Get the LogSubscriptions Durable Object for this twist (sharded by twistRootId)
      const logSubscriptionsId = env.LOG_SUBSCRIPTIONS.idFromName(twistRootId);
      const logSubscriptions = env.LOG_SUBSCRIPTIONS.get(logSubscriptionsId);

      // Get subscribers for this twist
      const subscribersResult = await logSubscriptions.getSubscribers(twistRootId);
      // Copy array before disposing RPC result
      const subscribers = [...subscribersResult];
      disposeRpc(subscribersResult);

      // Convert logs to the format expected by the callback
      const formattedLogs = logs.map((log) => ({
        timestamp: new Date(log.timestamp),
        environment: log.environment,
        severity: log.severity,
        message: log.message,
      }));

      // Send to callback subscribers
      if (subscribers.length > 0) {
        for (const callbackToken of subscribers) {
          try {
            await Callbacks.CallCallback(
              env.CALLBACKS,
              callbackToken as Callback,
              formattedLogs
            );
          } catch (error) {
            const context = extractLogQueueContext(logs[0], batch.queue);
            const logger = createLogger(context);
            logger.error("Failed to call log callback", error as Error, {
              callback_token: callbackToken,
            });
            postHog.captureException(error as Error, undefined, {
              twist_root_id: twistRootId,
              queue: batch.queue,
            });
          }
        }
      }

      // Also send to any active log streams (for API clients)
      try {
        const logStreamId = env.LOG_STREAM.idFromName(twistRootId);
        const logStream = env.LOG_STREAM.get(logStreamId);
        const sendResult = await logStream.sendLogs(logs);
        disposeRpc(sendResult);
      } catch (error) {
        const context = extractLogQueueContext(logs[0], batch.queue);
        const logger = createLogger(context);
        logger.error("Failed to send logs to stream", error as Error);
        postHog.captureException(error as Error, undefined, {
          twist_root_id: twistRootId,
          queue: batch.queue,
        });
      }

      // Persist logs to Logs activity
      try {
        await addLogsNote(env, twistRootId, logs);
      } catch (error) {
        // Log but don't fail the queue processing
        const context = extractLogQueueContext(logs[0], batch.queue);
        const logger = createLogger(context);
        logger.error("Failed to persist logs to activity", error as Error);
      }
    } catch (error) {
      const logger = createLogger({ twist_root_id: twistRootId, queue: batch.queue });
      logger.error("Error processing logs for twist", error as Error);
      postHog.captureException(error as Error, undefined, {
        twist_root_id: twistRootId,
        queue: batch.queue,
      });
    }
  }
}
