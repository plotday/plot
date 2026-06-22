/**
 * Delivery-attempt budget for a transient/infra failure on a queue consumer
 * before we give up and report it. Neither the run queue nor the webhook queue
 * has a dead-letter queue, so once Cloudflare's `max_retries` (default 3 — see
 * wrangler.jsonc `run-production` / `webhook-production`) is exhausted the
 * platform silently drops the message. Without a terminal report, a *persistent*
 * infra failure — e.g. an isolate that OOMs ("Worker exceeded memory limit.") on
 * every attempt — would retry-storm and then vanish with no signal. Mirrors the
 * `attempts < 3` give-up in `queue/mail.ts`.
 */
export const QUEUE_MAX_ATTEMPTS = 3;

/**
 * True once a queued message has burned through {@link QUEUE_MAX_ATTEMPTS}
 * deliveries. A transient blip that recovers on retry (attempts 1-2) returns
 * false and stays silent; a persistent failure returns true on the final
 * delivery so it's captured exactly once before being dropped.
 *
 * `attempts` is Cloudflare's 1-based `Message.attempts` (the delivery count).
 */
export function isQueueRetryExhausted(attempts: number): boolean {
  return attempts >= QUEUE_MAX_ATTEMPTS;
}
