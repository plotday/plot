import type { PostHog } from "posthog-node";
import {
  backgroundPressure,
  shouldDefer,
  backoffDelaySeconds,
} from "@plotday/worker-util";

type ShedMessage = { attempts: number; retry: (opts?: { delaySeconds: number }) => void };
type ShedBatch = { queue: string; messages: readonly ShedMessage[] };

/**
 * If background DB pressure is high, defer the WHOLE batch (retry every message
 * with a jittered delay) instead of opening connections onto a saturated origin.
 * Returns true when it deferred — the caller must then return without
 * processing. Emits a bg.deferred counter (NOT captureException — expected,
 * self-healing load-shed).
 */
export function shedBatchIfHot(
  batch: ShedBatch,
  posthog: PostHog,
  queueLabel: string,
  nowMs: number = Date.now(),
  rng: () => number = Math.random
): boolean {
  const decision = shouldDefer(backgroundPressure, nowMs);
  if (!decision.defer) return false;
  for (const message of batch.messages) {
    message.retry({ delaySeconds: backoffDelaySeconds(message.attempts, rng) });
  }
  posthog.capture({
    distinctId: "system",
    event: "bg.deferred",
    properties: {
      queue: queueLabel,
      reason: decision.reason,
      batch_size: batch.messages.length,
      ewma_ms: Math.round(backgroundPressure.ewmaMs),
    },
  });
  return true;
}
