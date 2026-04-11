import type { PostHog } from "posthog-node";

import { createLogger } from "@plotday/worker-util";

import { type Bindings, type WebhookMessage } from "../env";
import { isCallbackError, getCallbackErrorType } from "../errors";
import { Network } from "../twist/tools/network";

/**
 * Process async webhook deliveries from WEBHOOK_QUEUE.
 *
 * The /hook/:token ingress enqueues payloads and returns 200 immediately so
 * senders (Attio, etc.) never block on the DB. This consumer drains the
 * queue with bounded concurrency (configured in wrangler.jsonc), so the
 * number of in-flight callbacks — and therefore the number of open pg
 * connections through the CallbacksState DO path — stays capped regardless
 * of how bursty the ingress is.
 *
 * Failure handling: Cloudflare Queues retries messages that throw. Permanent
 * failures (expired/deleted callbacks) are acked so they don't retry. Other
 * errors retry up to the queue's DLQ policy.
 */
export async function processWebhooks(
  batch: MessageBatch<WebhookMessage>,
  env: Bindings,
  postHog: PostHog
): Promise<void> {
  const logger = createLogger({
    queue: batch.queue,
    batch_size: batch.messages.length,
  });

  for (const message of batch.messages) {
    const { token, method, headers, params, body, rawBody } = message.body;
    try {
      using _result = await Network.HandleWebhook(env.CALLBACKS, token, {
        method,
        headers,
        params,
        body,
        rawBody,
      });
      message.ack();
    } catch (error) {
      // Permanent failures — ack so the queue doesn't retry forever.
      if (isCallbackError(error)) {
        const errorType = getCallbackErrorType(error as Error);
        if (
          errorType === "NOT_FOUND" ||
          errorType === "EXPIRED" ||
          errorType === "INVALID_TOKEN" ||
          errorType === "INVALID_TOKEN_FORMAT"
        ) {
          logger.warn("Dropping webhook for permanently unavailable callback", {
            errorType,
            token: token.substring(0, 8) + "...",
          });
          message.ack();
          continue;
        }
      }

      // Transient failures — let the queue retry.
      logger.error("Error processing queued webhook", error as Error, {
        token: token.substring(0, 8) + "...",
      });
      postHog.captureException(error as Error, undefined, {
        queue: batch.queue,
        token: token.substring(0, 8) + "...",
      });
      message.retry();
    }
  }
}
