import { describe, it, expect, vi, beforeEach } from "vitest";
import { backgroundPressure, recordTimeout } from "@plotday/worker-util";
import { shedBatchIfHot } from "./shed";

function fakeBatch(n: number) {
  const messages = Array.from({ length: n }, (_, i) => ({
    attempts: 1,
    retry: vi.fn(),
    ack: vi.fn(),
    body: { i },
  }));
  return { queue: "updates-production", messages } as any;
}

const posthog = { capture: vi.fn() } as any;

describe("shedBatchIfHot", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("does nothing when the DB is healthy", () => {
    // fresh pressure: no samples, no timeout
    backgroundPressure.samples = 0;
    backgroundPressure.ewmaMs = 0;
    backgroundPressure.lastTimeoutAtMs = 0;
    const batch = fakeBatch(3);
    const deferred = shedBatchIfHot(batch, posthog, "updates", 5000);
    expect(deferred).toBe(false);
    expect(batch.messages[0].retry).not.toHaveBeenCalled();
  });

  it("retries every message with a delay when pressure is hot", () => {
    recordTimeout(backgroundPressure, 5000); // within cooldown of now=5000
    const batch = fakeBatch(3);
    const deferred = shedBatchIfHot(batch, posthog, "updates", 5000, () => 0);
    expect(deferred).toBe(true);
    for (const m of batch.messages) {
      expect(m.retry).toHaveBeenCalledWith({
        delaySeconds: expect.any(Number),
      });
    }
    expect(posthog.capture).toHaveBeenCalledWith(
      expect.objectContaining({ event: "bg.deferred" })
    );
  });
});
