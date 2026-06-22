import type { PostHog } from "posthog-node";

import { createLogger } from "@plotday/worker-util";

import { type Bindings, type WebhookMessage } from "../env";
import { isCallbackError, getCallbackErrorType } from "../errors";
import { invokeWebhookCallback } from "../twist/invoke-webhook";
import { disposeRpc } from "../utils/rpc";
import { isQueueRetryExhausted } from "./retry";
import { isTransientError } from "../utils/transient-error";
import { parseBodyFromRaw } from "../webhook";

// Cloudflare resets a Durable Object when an in-flight call holds its
// storage gate past the platform's watchdog. The new helper runs the
// twist RPC outside the CallbacksState DO, but we keep this detection in
// place for any remaining DO hop (validateAndLoad, delete) and for the
// back-compat CallCallback path reachable from other routes.
function isDurableObjectResetError(error: unknown): boolean {
  const msg = (error as Error)?.message ?? "";
  return msg.includes("Durable Object storage operation exceeded timeout");
}

/**
 * Process async webhook deliveries from WEBHOOK_QUEUE.
 *
 * Each message runs through `invokeWebhookCallback` independently — no
 * shared state, no shared retry fate. The consumer dispatches the whole
 * batch in parallel via `Promise.allSettled` so one slow callback cannot
 * block the other nine in the same batch. Cloudflare Queues redelivers
 * on retry(), so a transient failure in one callback never affects its
 * neighbours.
 *
 * Error taxonomy:
 * - `CallbackError` NOT_FOUND / EXPIRED / INVALID_TOKEN*: permanent. Ack.
 * - `CallbackError` SUSPENDED: retriable once the twist resumes.
 * - Durable Object reset / transient infra errors: retry, warn only.
 * - Anything else: retry + capture to PostHog.
 */
export async function processWebhooks(
  batch: MessageBatch<WebhookMessage>,
  env: Bindings,
  ctx: { exports: ExecutionContext["exports"] },
  postHog: PostHog
): Promise<void> {
  const logger = createLogger({
    queue: batch.queue,
    batch_size: batch.messages.length,
  });

  const handleMessage = async (
    message: Message<WebhookMessage>
  ): Promise<void> => {
    const { token, method, headers, params, rawBody } = message.body;
    // The /hook/:token producer omits the parsed `body` to halve the queue
    // payload (Cloudflare Queues caps messages at 128 KB). Reconstruct it
    // here so the downstream `invokeWebhookCallback` contract is unchanged.
    const body =
      message.body.body !== undefined
        ? message.body.body
        : parseBodyFromRaw(rawBody, headers?.["content-type"], logger);
    try {
      const result = await invokeWebhookCallback(env, ctx, token, {
        method,
        headers,
        params,
        body,
        rawBody,
      });
      // The twist worker may return an RPC stub (e.g. wrapped tool
      // response). Dispose to avoid "RPC stub was not disposed properly"
      // warnings in the runtime.
      disposeRpc(result);
      message.ack();
    } catch (error) {
      if (isCallbackError(error)) {
        const errorType = getCallbackErrorType(error as Error);
        if (
          errorType === "NOT_FOUND" ||
          errorType === "EXPIRED" ||
          errorType === "INVALID_TOKEN" ||
          errorType === "INVALID_TOKEN_FORMAT"
        ) {
          logger.warn(
            "Dropping webhook for permanently unavailable callback",
            {
              errorType,
              token: token.substring(0, 8) + "...",
            }
          );
          message.ack();
          return;
        }
        // SUSPENDED or anything else CallbackError-shaped: retry.
        logger.warn("Callback unavailable, retrying", {
          errorType,
          token: token.substring(0, 8) + "...",
        });
        message.retry();
        return;
      }

      if (isDurableObjectResetError(error)) {
        logger.warn("Durable Object reset during webhook callback, retrying", {
          token: token.substring(0, 8) + "...",
        });
        message.retry();
        return;
      }

      if (isTransientError(error)) {
        // Persistent failure guard (mirrors Tasks.processQueue): the webhook
        // queue has no DLQ, so once retries are exhausted Cloudflare drops the
        // message silently. If a transient error keeps failing to the attempt
        // cap (e.g. an isolate that OOMs every attempt, not just a one-off
        // spike), report it ONCE before giving up — otherwise a real
        // infra/memory regression would vanish. A blip that recovers on
        // attempts 1-2 never reaches this and stays quiet.
        if (isQueueRetryExhausted(message.attempts)) {
          logger.error(
            "Transient error processing webhook exhausted retries",
            error as Error,
            {
              token: token.substring(0, 8) + "...",
              attempts: message.attempts,
            }
          );
          postHog.captureException(error as Error, undefined, {
            queue: batch.queue,
            token: token.substring(0, 8) + "...",
            attempts: message.attempts,
            outcome: "transient_exhausted",
          });
          message.ack();
          return;
        }
        logger.warn("Transient error processing webhook, retrying", {
          token: token.substring(0, 8) + "...",
          error: String(error),
          attempts: message.attempts,
        });
        message.retry();
        return;
      }

      logger.error("Error processing queued webhook", error as Error, {
        token: token.substring(0, 8) + "...",
      });
      postHog.captureException(error as Error, undefined, {
        queue: batch.queue,
        token: token.substring(0, 8) + "...",
      });
      message.retry();
    }
  };

  await Promise.allSettled(batch.messages.map(handleMessage));
}
