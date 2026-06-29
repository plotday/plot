import { describe, expect, it } from "vitest";
import { cancellationIsForPastEventFn } from "./apple-calendar";

describe("cancellationIsForPastEventFn (apple-calendar)", () => {
  const now = new Date("2026-06-29T12:00:00.000Z");

  it("treats a timed event that has already ended as past", () => {
    const start = new Date("2026-06-27T10:00:00.000Z");
    const end = new Date("2026-06-27T11:00:00.000Z");
    expect(cancellationIsForPastEventFn(start, end, now)).toBe(true);
  });

  it("keeps a timed event that has started but not finished", () => {
    const start = new Date("2026-06-29T11:00:00.000Z");
    const end = new Date("2026-06-29T13:00:00.000Z"); // still running at noon
    expect(cancellationIsForPastEventFn(start, end, now)).toBe(false);
  });

  it("keeps a future timed event", () => {
    const start = new Date("2026-07-05T10:00:00.000Z");
    const end = new Date("2026-07-05T11:00:00.000Z");
    expect(cancellationIsForPastEventFn(start, end, now)).toBe(false);
  });

  it("treats a timed event with no end whose start is past as past", () => {
    const start = new Date("2026-06-27T10:00:00.000Z");
    expect(cancellationIsForPastEventFn(start, null, now)).toBe(true);
  });

  it("treats an all-day event from yesterday as past (DTEND exclusive)", () => {
    // All-day on 2026-06-28: DTSTART 2026-06-28, DTEND 2026-06-29 (exclusive).
    expect(cancellationIsForPastEventFn("2026-06-28", "2026-06-29", now)).toBe(
      true
    );
  });

  it("keeps an all-day event happening today (no end, runs to end of day)", () => {
    // DTSTART 2026-06-29 with no DTEND → runs until 2026-06-30 midnight.
    expect(cancellationIsForPastEventFn("2026-06-29", null, now)).toBe(false);
  });

  it("keeps a multi-day all-day event still in progress", () => {
    // 2026-06-28 .. 2026-07-01 (exclusive end) — ends in the future.
    expect(cancellationIsForPastEventFn("2026-06-28", "2026-07-01", now)).toBe(
      false
    );
  });
});
