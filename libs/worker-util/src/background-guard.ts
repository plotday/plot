/**
 * Self-throttling signal for BACKGROUND database work. Background queries
 * running slow IS the CPU-pressure proxy for the shared (single-vCPU) Postgres
 * origin: "my queries are slow → the DB is hot → yield". Queue dispatchers call
 * shouldDefer() at batch start and defer the batch (retry-with-delay) instead of
 * piling onto a saturated backend. State is a module-global so signal carries
 * across batches on a warm isolate; it is best-effort (cold isolates start clean,
 * and correctness never depends on it persisting).
 *
 * NOT used by the frontend lane — the frontend never backs off; it is the thing
 * being protected.
 */
export type BackgroundPressure = {
  ewmaMs: number;
  samples: number;
  lastTimeoutAtMs: number;
};

// Conservative first cut — favor NOT deferring. Normal background query is
// <120ms warm in prod; a sustained EWMA over 2s means real saturation. Tune from
// the bg.deferred counters after deploy.
export const EWMA_ALPHA = 0.3;
export const DEFER_EWMA_MS = 2000;
export const TIMEOUT_COOLDOWN_MS = 30_000;
export const BACKOFF_BASE_MS = 1000;
export const BACKOFF_CAP_MS = 30_000;

export function createPressure(): BackgroundPressure {
  return { ewmaMs: 0, samples: 0, lastTimeoutAtMs: 0 };
}

/** Shared across all background batches on this isolate. */
export const backgroundPressure: BackgroundPressure = createPressure();

export function recordLatency(p: BackgroundPressure, ms: number): void {
  p.ewmaMs =
    p.samples === 0 ? ms : EWMA_ALPHA * ms + (1 - EWMA_ALPHA) * p.ewmaMs;
  p.samples += 1;
}

export function recordTimeout(p: BackgroundPressure, nowMs: number): void {
  p.lastTimeoutAtMs = nowMs;
}

export type DeferReason = "none" | "ewma_high" | "recent_timeout";

export function shouldDefer(
  p: BackgroundPressure,
  nowMs: number
): { defer: boolean; reason: DeferReason } {
  if (p.lastTimeoutAtMs > 0 && nowMs - p.lastTimeoutAtMs < TIMEOUT_COOLDOWN_MS) {
    return { defer: true, reason: "recent_timeout" };
  }
  if (p.samples > 0 && p.ewmaMs > DEFER_EWMA_MS) {
    return { defer: true, reason: "ewma_high" };
  }
  return { defer: false, reason: "none" };
}

/** Exponential backoff with equal jitter, capped, expressed in whole seconds
 *  (Cloudflare Queues `retry({ delaySeconds })` granularity). `attempts` is the
 *  message delivery count. rng injected for deterministic tests. */
export function backoffDelaySeconds(
  attempts: number,
  rng: () => number = Math.random
): number {
  const ceilingMs = Math.min(
    BACKOFF_CAP_MS,
    BACKOFF_BASE_MS * 2 ** Math.max(0, attempts - 1)
  );
  const halfMs = ceilingMs / 2;
  const ms = halfMs + rng() * halfMs;
  return Math.max(1, Math.round(ms / 1000));
}
