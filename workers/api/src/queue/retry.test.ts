import { describe, expect, it } from "vitest";

import { QUEUE_MAX_ATTEMPTS, isQueueRetryExhausted } from "./retry";

describe("isQueueRetryExhausted", () => {
  it("stays quiet while a transient error can still self-resolve on retry", () => {
    // A single isolate OOM that recovers on the next delivery (attempts 1-2)
    // must NOT be captured — that's the noise the transient classification
    // removes. Shared by the run queue (Tasks.processQueue) and the webhook
    // queue (processWebhooks).
    expect(isQueueRetryExhausted(1)).toBe(false);
    expect(isQueueRetryExhausted(2)).toBe(false);
  });

  it("reports once retries are exhausted (no DLQ → the message is dropped)", () => {
    // No queue has a dead-letter queue and Cloudflare's default max_retries is
    // 3, so on the final delivery the message is about to be dropped. A
    // *persistent* failure (e.g. an isolate OOMing every attempt) must surface
    // here instead of vanishing silently.
    expect(isQueueRetryExhausted(QUEUE_MAX_ATTEMPTS)).toBe(true);
    expect(isQueueRetryExhausted(QUEUE_MAX_ATTEMPTS + 1)).toBe(true);
  });
});
