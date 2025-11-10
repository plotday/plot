import type { PostHog } from "posthog-node";

import type { Callback } from "@plotday/twister/tools/callbacks";

import { Callbacks } from "../twist/tools/callbacks";
import { type Bindings, type LogMessage } from "../env";

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
      const subscribers = await logSubscriptions.getSubscribers(twistRootId);

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
            console.error(
              `Failed to call log callback ${callbackToken}:`,
              error
            );
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
        console.error(
          `Failed to send logs to stream for twist ${twistRootId}:`,
          error
        );
        postHog.captureException(error as Error, undefined, {
          twist_root_id: twistRootId,
          queue: batch.queue,
        });
      }
    } catch (error) {
      console.error(`Error processing logs for twist ${twistRootId}:`, error);
      postHog.captureException(error as Error, undefined, {
        twist_root_id: twistRootId,
        queue: batch.queue,
      });
    }
  }
}
