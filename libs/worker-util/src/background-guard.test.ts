import { describe, it, expect } from "vitest";
import {
  createPressure,
  recordLatency,
  recordTimeout,
  shouldDefer,
  backoffDelaySeconds,
  DEFER_EWMA_MS,
  TIMEOUT_COOLDOWN_MS,
} from "./background-guard";

describe("recordLatency / shouldDefer (EWMA)", () => {
  it("does not defer when no samples", () => {
    expect(shouldDefer(createPressure(), 1000).defer).toBe(false);
  });

  it("does not defer on fast background queries", () => {
    const p = createPressure();
    for (let i = 0; i < 10; i++) recordLatency(p, 80);
    expect(shouldDefer(p, 1000)).toEqual({ defer: false, reason: "none" });
  });

  it("defers once EWMA climbs above the saturation threshold", () => {
    const p = createPressure();
    for (let i = 0; i < 20; i++) recordLatency(p, DEFER_EWMA_MS + 1500);
    const d = shouldDefer(p, 1000);
    expect(d).toEqual({ defer: true, reason: "ewma_high" });
  });
});

describe("recordTimeout / shouldDefer (cooldown)", () => {
  it("defers within the cooldown window after a timeout", () => {
    const p = createPressure();
    recordTimeout(p, 1000);
    expect(shouldDefer(p, 1000 + TIMEOUT_COOLDOWN_MS - 1)).toEqual({
      defer: true,
      reason: "recent_timeout",
    });
  });

  it("stops deferring after the cooldown elapses", () => {
    const p = createPressure();
    recordTimeout(p, 1000);
    expect(shouldDefer(p, 1000 + TIMEOUT_COOLDOWN_MS + 1).defer).toBe(false);
  });
});

describe("backoffDelaySeconds", () => {
  it("grows with attempts and is bounded ≥ 1s", () => {
    const rng = () => 0; // floor of the jitter band
    expect(backoffDelaySeconds(1, rng)).toBeGreaterThanOrEqual(1);
    expect(backoffDelaySeconds(5, rng)).toBeGreaterThan(backoffDelaySeconds(1, rng));
  });

  it("caps the delay", () => {
    const rng = () => 1; // top of the jitter band
    expect(backoffDelaySeconds(50, rng)).toBeLessThanOrEqual(30);
  });
});
