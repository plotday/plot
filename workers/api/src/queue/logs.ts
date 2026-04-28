import type { PostHog } from "posthog-node";

import { addLogsNote } from "../twist/dev-activities";
import { type Bindings, type LogMessage } from "../env";
import { isCallbackError } from "../errors";
import { invokeWebhookCallback } from "../twist/invoke-webhook";
import { extractLogQueueContext } from "../utils/log-context";
import { createLogger } from "@plotday/worker-util";
import { disposeRpc } from "../utils/rpc";

export async function processLogs(
  batch: MessageBatch<LogMessage>,
  env: Bindings,
  ctx: { exports: ExecutionContext["exports"] },
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
      // Copy array for local use
      const subscribers = [...subscribersResult];

      // Convert logs to the format expected by the callback
      const formattedLogs = logs.map((log) => ({
        timestamp: new Date(log.timestamp),
        environment: log.environment,
        severity: log.severity,
        message: log.message,
      }));

      // Send to callback subscribers. Routed through invokeWebhookCallback
      // so the twist worker RPC runs in this consumer's context — keeps the
      // CallbacksState DO output gate free for the cheap SQLite token
      // lookup (the legacy DO-hosted callCallback held the gate across
      // Hyperdrive queries, which Cloudflare resets under load).
      if (subscribers.length > 0) {
        for (const callbackToken of subscribers) {
          try {
            const result = await invokeWebhookCallback(
              env,
              ctx,
              callbackToken,
              formattedLogs
            );
            disposeRpc(result);
          } catch (error) {
            const context = extractLogQueueContext(logs[0], batch.queue);
            const logger = createLogger(context);
            // Expired / not-found / suspended callbacks are expected — log
            // a warning instead of paging via PostHog.
            if (isCallbackError(error)) {
              logger.warn("Log callback unavailable", {
                callback_token: callbackToken,
                error: String(error),
              });
              continue;
            }
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
        await logStream.sendLogs(logs);
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
