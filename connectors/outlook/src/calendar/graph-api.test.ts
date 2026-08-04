/**
 * Unit tests for fromMsDate's timezone handling.
 *
 * Every Graph request sends `Prefer: outlook.timezone="UTC"`, so `timeZone`
 * is normally always "UTC". Microsoft Graph does not honor that header on
 * `/events/delta` requests though (the ongoing webhook-driven incremental
 * sync), so events synced through that path come back with `timeZone` set
 * to the mailbox's default zone instead. fromMsDate must convert those
 * correctly rather than misreading the wall-clock value as UTC.
 */

import { afterEach, describe, expect, it, vi } from "vitest";
import { fromMsDate, GraphApi, syncOutlookCalendar } from "./graph-api";
import type { OutlookEvent, SyncState } from "./graph-api";

describe("fromMsDate", () => {
  it("parses a UTC dateTime unchanged (the normal, Prefer-honored path)", () => {
    const result = fromMsDate({
      dateTime: "2026-08-04T14:00:00.0000000",
      timeZone: "UTC",
    });
    expect(result?.toISOString()).toBe("2026-08-04T14:00:00.000Z");
  });

  it("converts an Eastern-time wall clock during EDT (delta-query fallback)", () => {
    // Mailbox default zone leaked through on a delta query: wall clock 10:00
    // in "Eastern Standard Time" (Windows' name for the zone year-round) is
    // actually EDT (UTC-4) in August, i.e. 14:00 UTC. Naively appending "Z"
    // (the pre-fix behavior) would have produced 10:00Z — 4 hours earlier
    // than the true instant, matching the reported bug.
    const result = fromMsDate({
      dateTime: "2026-08-04T10:00:00.0000000",
      timeZone: "Eastern Standard Time",
    });
    expect(result?.toISOString()).toBe("2026-08-04T14:00:00.000Z");
  });

  it("converts an Eastern-time wall clock during EST (winter, UTC-5)", () => {
    const result = fromMsDate({
      dateTime: "2026-01-04T10:00:00.0000000",
      timeZone: "Eastern Standard Time",
    });
    expect(result?.toISOString()).toBe("2026-01-04T15:00:00.000Z");
  });

  it("converts other common Windows zones", () => {
    expect(
      fromMsDate({
        dateTime: "2026-08-04T10:00:00.0000000",
        timeZone: "Pacific Standard Time",
      })?.toISOString()
    ).toBe("2026-08-04T17:00:00.000Z"); // PDT = UTC-7 in August

    expect(
      fromMsDate({
        dateTime: "2026-08-04T10:00:00.0000000",
        timeZone: "India Standard Time",
      })?.toISOString()
    ).toBe("2026-08-04T04:30:00.000Z"); // IST = UTC+5:30, no DST
  });

  it("falls back to the naive UTC interpretation for an unmapped zone, and logs it", () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const result = fromMsDate({
      dateTime: "2026-08-04T10:00:00.0000000",
      timeZone: "Some Unmapped Zone",
    });
    expect(result?.toISOString()).toBe("2026-08-04T10:00:00.000Z");
    expect(errorSpy).toHaveBeenCalledWith(
      expect.stringContaining("Some Unmapped Zone")
    );
    errorSpy.mockRestore();
  });

  it("returns undefined for a missing dateTime", () => {
    expect(fromMsDate(undefined)).toBeUndefined();
    expect(fromMsDate({ dateTime: "", timeZone: "UTC" })).toBeUndefined();
  });
});

/**
 * Unit tests for syncOutlookCalendar's expansion of property-starved delta
 * entries.
 *
 * Per Microsoft's own docs (event: delta, beta), the unbounded
 * `/events/delta` chain returns only `id`, `type`, `start`, and `end` for
 * each changed event — no `subject`, `body`, `organizer`, `attendees`,
 * `seriesMasterId`, or `originalStart`. That's the resource used for both
 * the historical full-pass backfill and every webhook-driven incremental
 * sync going forward, so without expansion every synced event comes back
 * Untitled with no notes. syncOutlookCalendar must follow up with
 * `GET /events/{id}` per entry to restore the full event.
 */
describe("syncOutlookCalendar — delta entry expansion", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  function mockFetch(handlers: {
    delta: unknown;
    byId: Record<string, unknown>;
  }) {
    const calledUrls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        calledUrls.push(input);
        const url = new URL(input);
        if (url.pathname.endsWith("/delta")) {
          return new Response(JSON.stringify(handlers.delta), {
            status: 200,
          });
        }
        const id = decodeURIComponent(url.pathname.split("/").pop() ?? "");
        const body = handlers.byId[id];
        if (body === undefined) {
          return new Response(null, { status: 404 });
        }
        return new Response(JSON.stringify(body), { status: 200 });
      })
    );
    return calledUrls;
  }

  it("expands each minimal delta entry with a full GET /events/{id}", async () => {
    const minimalEvent: Partial<OutlookEvent> = {
      id: "evt-1",
      type: "singleInstance",
      start: { dateTime: "2026-08-04T14:00:00.0000000", timeZone: "UTC" },
      end: { dateTime: "2026-08-04T15:00:00.0000000", timeZone: "UTC" },
    };
    const fullEvent: OutlookEvent = {
      ...(minimalEvent as OutlookEvent),
      subject: "Real title",
      body: { contentType: "text", content: "Real notes" },
      organizer: {
        emailAddress: { address: "a@example.com", name: "A" },
      },
    };

    mockFetch({
      delta: {
        value: [minimalEvent],
        "@odata.deltaLink":
          "https://graph.microsoft.com/v1.0/me/events/delta?$deltatoken=abc",
      },
      byId: { "evt-1": fullEvent },
    });

    const api = new GraphApi("token");
    const state: SyncState = { calendarId: "primary", sequence: 1 };
    const result = await syncOutlookCalendar(api, "primary", state);

    expect(result.events).toEqual([fullEvent]);
  });

  it("leaves @removed entries alone (no expansion attempted)", async () => {
    const removed: Partial<OutlookEvent> = {
      id: "evt-gone",
      "@removed": { reason: "deleted" },
    };

    const calledUrls = mockFetch({
      delta: {
        value: [removed],
        "@odata.deltaLink":
          "https://graph.microsoft.com/v1.0/me/events/delta?$deltatoken=abc",
      },
      byId: {},
    });

    const api = new GraphApi("token");
    const state: SyncState = { calendarId: "primary", sequence: 1 };
    const result = await syncOutlookCalendar(api, "primary", state);

    expect(result.events).toEqual([removed]);
    expect(calledUrls.some((u) => u.includes("evt-gone"))).toBe(false);
  });

  it("falls back to the minimal entry when expansion fails (e.g. deleted mid-sync)", async () => {
    const minimalEvent: Partial<OutlookEvent> = {
      id: "evt-2",
      type: "singleInstance",
      start: { dateTime: "2026-08-04T14:00:00.0000000", timeZone: "UTC" },
      end: { dateTime: "2026-08-04T15:00:00.0000000", timeZone: "UTC" },
    };

    mockFetch({
      delta: {
        value: [minimalEvent],
        "@odata.deltaLink":
          "https://graph.microsoft.com/v1.0/me/events/delta?$deltatoken=abc",
      },
      byId: {}, // GET /events/evt-2 -> 404
    });

    const api = new GraphApi("token");
    const state: SyncState = { calendarId: "primary", sequence: 1 };
    const result = await syncOutlookCalendar(api, "primary", state);

    expect(result.events).toEqual([minimalEvent]);
  });

  it("does NOT expand entries from the bounded (plain listing) quick-pass path", async () => {
    const fullEvent: OutlookEvent = {
      id: "evt-3",
      type: "singleInstance",
      subject: "Already full",
      body: { contentType: "text", content: "notes" },
      start: { dateTime: "2026-08-04T14:00:00.0000000", timeZone: "UTC" },
      end: { dateTime: "2026-08-04T15:00:00.0000000", timeZone: "UTC" },
    };

    const calledUrls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        calledUrls.push(input);
        return new Response(
          JSON.stringify({
            value: [fullEvent],
            "@odata.nextLink": undefined,
          }),
          { status: 200 }
        );
      })
    );

    const api = new GraphApi("token");
    const state: SyncState = {
      calendarId: "primary",
      sequence: 1,
      min: new Date("2026-08-01T00:00:00.000Z"),
    };
    const result = await syncOutlookCalendar(api, "primary", state);

    expect(result.events).toEqual([fullEvent]);
    // Only the one listing request — no per-event expansion GET.
    expect(calledUrls).toHaveLength(1);
  });
});
