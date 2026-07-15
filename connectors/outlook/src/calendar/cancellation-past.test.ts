import { describe, expect, it } from "vitest";
import type { OutlookEvent } from "./graph-api";
import { cancellationIsForPastEventFn } from "./sync";

// Minimal OutlookEvent factory — only the fields the guard reads.
const ev = (partial: Partial<OutlookEvent>): OutlookEvent =>
  partial as OutlookEvent;

const utc = (iso: string) => ({ dateTime: iso, timeZone: "UTC" });

describe("cancellationIsForPastEventFn (outlook-calendar)", () => {
  const now = new Date("2026-06-29T12:00:00.000Z");

  it("treats an event that has already ended as past", () => {
    const event = ev({
      start: utc("2026-06-27T10:00:00.0000000"),
      end: utc("2026-06-27T11:00:00.0000000"),
    });
    expect(cancellationIsForPastEventFn(event, now)).toBe(true);
  });

  it("keeps an event that has started but not finished", () => {
    const event = ev({
      start: utc("2026-06-29T11:00:00.0000000"),
      end: utc("2026-06-29T13:00:00.0000000"), // still running at noon
    });
    expect(cancellationIsForPastEventFn(event, now)).toBe(false);
  });

  it("keeps a future event", () => {
    const event = ev({
      start: utc("2026-07-05T10:00:00.0000000"),
      end: utc("2026-07-05T11:00:00.0000000"),
    });
    expect(cancellationIsForPastEventFn(event, now)).toBe(false);
  });

  it("uses originalStart for a cancelled occurrence with no end", () => {
    const event = ev({ originalStart: "2026-06-20T10:00:00.0000000" });
    expect(cancellationIsForPastEventFn(event, now)).toBe(true);
  });

  it("keeps a future cancelled occurrence (originalStart only)", () => {
    const event = ev({ originalStart: "2026-07-10T10:00:00.0000000" });
    expect(cancellationIsForPastEventFn(event, now)).toBe(false);
  });

  it("keeps a delta-removed event with no time data (cannot judge)", () => {
    // Graph returns @removed items with only an id — no start/end/originalStart.
    const event = ev({ id: "abc", "@removed": { reason: "deleted" } });
    expect(cancellationIsForPastEventFn(event, now)).toBe(false);
  });
});
