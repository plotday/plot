import { describe, expect, it } from "vitest";

import { computeEngagement, MIN_ENGAGEMENT_HISTORY } from "./engagement";

describe("computeEngagement", () => {
  it("returns null rates below the minimum history but still reports priorThreads", () => {
    const r = computeEngagement({
      priorThreads: MIN_ENGAGEMENT_HISTORY - 1,
      readCount: 0,
      archivedUnreadCount: 2,
      replyCount: 0,
    });
    expect(r.priorThreads).toBe(MIN_ENGAGEMENT_HISTORY - 1);
    expect(r.readRate).toBeNull();
    expect(r.archivedUnreadRate).toBeNull();
    expect(r.replyRate).toBeNull();
  });

  it("computes rates once enough history exists", () => {
    const r = computeEngagement({
      priorThreads: 10,
      readCount: 1,
      archivedUnreadCount: 8,
      replyCount: 0,
    });
    expect(r.priorThreads).toBe(10);
    expect(r.readRate).toBeCloseTo(0.1, 5);
    expect(r.archivedUnreadRate).toBeCloseTo(0.8, 5);
    expect(r.replyRate).toBeCloseTo(0, 5);
  });

  it("handles a fully-engaged sender", () => {
    const r = computeEngagement({
      priorThreads: 6,
      readCount: 6,
      archivedUnreadCount: 0,
      replyCount: 5,
    });
    expect(r.readRate).toBeCloseTo(1, 5);
    expect(r.replyRate).toBeCloseTo(5 / 6, 5);
  });

  it("treats zero history as priorThreads 0, null rates", () => {
    const r = computeEngagement({
      priorThreads: 0,
      readCount: 0,
      archivedUnreadCount: 0,
      replyCount: 0,
    });
    expect(r.priorThreads).toBe(0);
    expect(r.readRate).toBeNull();
  });
});
