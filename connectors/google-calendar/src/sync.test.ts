/**
 * Unit tests for runSyncBatch and runCalendarInit.
 *
 * Tests use a fake CalendarSyncHost that stubs out all tool access so no real
 * network or storage is needed. Fetch is stubbed for GoogleApi calls.
 */

import { afterEach, describe, expect, it, vi } from "vitest";
import type { NewLinkWithNotes } from "@plotday/twister";
import type { Thread } from "@plotday/twister";
import type { CalendarSyncHost } from "./sync";
import {
  cancelEventWithApiFn,
  cancellationWasSelfInitiatedFn,
  extractRSVPParamsFn,
  getWatchRenewalScheduleFn,
  processCalendarEventsFn,
  runCalendarInit,
  runSyncBatch,
  setupCalendarWatchFn,
  startIncrementalSyncFn,
  stopCalendarWatchFn,
  updateEventRSVPWithApiFn,
  validateCalendarWebhookFn,
} from "./sync";
import type { SyncState } from "./google-api";
import { GoogleApi } from "./google-api";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeEventsResponse(
  items: object[],
  nextPageToken?: string,
  nextSyncToken?: string
) {
  return new Response(
    JSON.stringify({
      items,
      ...(nextPageToken ? { nextPageToken } : {}),
      ...(nextSyncToken ? { nextSyncToken } : {}),
    }),
    { status: 200, headers: { "Content-Type": "application/json" } }
  );
}

function makeCalendarResponse(id: string) {
  return new Response(JSON.stringify({ id }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

function makeCalendarListResponse(id: string) {
  return new Response(JSON.stringify({ id }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

/**
 * Build a minimal fake CalendarSyncHost backed by an in-memory store.
 */
function makeFakeHost(overrides?: {
  token?: { token: string; scopes: string[] } | null;
  initialState?: SyncState;
  calendarId?: string;
}): CalendarSyncHost & {
  store: Map<string, unknown>;
  savedLinks: NewLinkWithNotes[][];
  syncCompletedCalls: string[];
  acquireLockResult: boolean;
  releaseLockCalls: string[];
} {
  const storeMap = new Map<string, unknown>();
  const savedLinks: NewLinkWithNotes[][] = [];
  const syncCompletedCalls: string[] = [];
  const releaseLockCalls: string[] = [];

  const calendarId = overrides?.calendarId ?? "user@example.com";
  const tokenValue = overrides?.token !== undefined
    ? overrides.token
    : { token: "fake-access-token", scopes: [] };

  // Seed the initial SyncState if provided
  if (overrides?.initialState) {
    storeMap.set(`sync_state_${calendarId}`, overrides.initialState);
  }

  const host: ReturnType<typeof makeFakeHost> = {
    store: storeMap,
    savedLinks,
    syncCompletedCalls,
    releaseLockCalls,
    acquireLockResult: true,

    set: async (key, value) => {
      storeMap.set(key, value);
    },
    get: async <T>(key: string): Promise<T | null> => {
      const val = storeMap.get(key);
      return val === undefined ? null : (val as T);
    },
    clear: async (key) => {
      storeMap.delete(key);
    },

    tools: {
      integrations: {
        get: async (_channelId) => tokenValue,
        saveLinks: async (links) => {
          savedLinks.push(links);
        },
        channelSyncCompleted: async (channelId) => {
          syncCompletedCalls.push(channelId);
        },
      },
      googleContacts: {
        // Minimal stub — enrichLinkContactsFromGoogle is best-effort
        SCOPES: [],
      } as any,
      store: {
        acquireLock: async (_key, _ttlMs) => host.acquireLockResult,
        releaseLock: async (key) => {
          releaseLockCalls.push(key);
        },
        list: async (prefix) => {
          const keys: string[] = [];
          for (const k of storeMap.keys()) {
            if (k.startsWith(prefix)) keys.push(k);
          }
          return keys;
        },
      },
    },
  };

  return host;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("runSyncBatch", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("returns { done: true } immediately when token is missing", async () => {
    const host = makeFakeHost({ token: null });

    const state: SyncState = {
      calendarId: "user@example.com",
      min: new Date(),
      max: null,
      sequence: 1,
      phase: "quick",
    };
    host.store.set("sync_state_user@example.com", state);

    const result = await runSyncBatch(
      host,
      1,
      "full",
      "user@example.com",
      true
    );

    expect(result).toEqual({ done: true });
    // Lock should be released on early exit
    expect(host.releaseLockCalls).toContain("sync_user@example.com");
  });

  it("returns { done: true } when no sync_state is found (stale callback)", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    // No sync_state stored → stale callback

    // Stub fetch for ensureUserIdentity (called on batch 1 before state check)
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => makeCalendarListResponse(calendarId))
    );

    const result = await runSyncBatch(host, 1, "full", calendarId, true);

    expect(result).toEqual({ done: true });
    expect(host.releaseLockCalls).toContain(`sync_${calendarId}`);
  });

  it("returns { next } with batchNumber+1 when there are more pages", async () => {
    const calendarId = "user@example.com";
    const state: SyncState = {
      calendarId,
      min: new Date("2024-01-01"),
      max: null,
      sequence: 1,
    };
    const host = makeFakeHost({ calendarId, initialState: state });

    // Stub fetch to return a page with a nextPageToken
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        if (url.includes("calendarList/primary")) {
          return makeCalendarListResponse(calendarId);
        }
        return makeEventsResponse([], "next-page-token-123");
      })
    );

    const result = await runSyncBatch(host, 3, "full", calendarId, false);

    expect(result).toEqual({
      next: { batchNumber: 4, mode: "full" },
    });
    // Lock must NOT be released between pages
    expect(host.releaseLockCalls).toHaveLength(0);
  });

  it("transitions quick→full and returns { next: { batchNumber: 1, mode: 'full' } }", async () => {
    const calendarId = "user@example.com";
    const quickState: SyncState = {
      calendarId,
      min: new Date(),
      max: null,
      sequence: 1,
      phase: "quick",
    };
    const host = makeFakeHost({ calendarId, initialState: quickState });

    // Return an empty events page with a nextSyncToken (no more pages)
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        if (url.includes("calendarList/primary")) {
          return makeCalendarListResponse(calendarId);
        }
        return makeEventsResponse([], undefined, "sync-token-abc");
      })
    );

    const result = await runSyncBatch(host, 1, "full", calendarId, true);

    expect(result).toEqual({
      next: { batchNumber: 1, mode: "full" },
    });

    // The full-phase state should be stored
    const storedState = host.store.get(`sync_state_${calendarId}`) as SyncState;
    expect(storedState.phase).toBe("full");
    expect(storedState.min).toBeInstanceOf(Date);

    // Lock should NOT be released yet (still in progress)
    expect(host.releaseLockCalls).toHaveLength(0);
  });

  it("full pass complete: returns { done: true }, signals channelSyncCompleted, releases lock", async () => {
    const calendarId = "user@example.com";
    const fullState: SyncState = {
      calendarId,
      min: new Date("2022-01-01"),
      max: null,
      sequence: 1,
      phase: "full",
    };
    const host = makeFakeHost({ calendarId, initialState: fullState });

    // Return an empty events page with a nextSyncToken (last page of full pass)
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        if (url.includes("calendarList/primary")) {
          return makeCalendarListResponse(calendarId);
        }
        return makeEventsResponse([], undefined, "sync-token-xyz");
      })
    );

    const result = await runSyncBatch(host, 1, "full", calendarId, true);

    expect(result).toEqual({ done: true });
    // channelSyncCompleted called with the calendar id
    expect(host.syncCompletedCalls).toContain(calendarId);
    // Lock released
    expect(host.releaseLockCalls).toContain(`sync_${calendarId}`);
    // sync_state cleared
    expect(host.store.has(`sync_state_${calendarId}`)).toBe(false);
  });

  it("saves transformed events via saveLinks", async () => {
    const calendarId = "user@example.com";
    const state: SyncState = {
      calendarId,
      min: new Date("2024-01-01"),
      max: null,
      sequence: 1,
      phase: "full",
    };
    const host = makeFakeHost({ calendarId, initialState: state });

    const event = {
      id: "event-1",
      iCalUID: "uid-1@google.com",
      status: "confirmed",
      summary: "Team Meeting",
      start: { dateTime: "2024-06-01T10:00:00Z" },
      end: { dateTime: "2024-06-01T11:00:00Z" },
    };

    let fetchCallCount = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        fetchCallCount++;
        if (url.includes("calendarList/primary")) {
          return makeCalendarListResponse(calendarId);
        }
        // First call: return the event; subsequent calls (enrichment): empty
        if (url.includes("/events") && fetchCallCount <= 2) {
          return makeEventsResponse([event], undefined, "sync-token");
        }
        return new Response(JSON.stringify({ connections: [] }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      })
    );

    const result = await runSyncBatch(host, 1, "full", calendarId, true);

    expect(result).toEqual({ done: true });
    // At least one saveLinks call with the event
    expect(host.savedLinks.length).toBeGreaterThan(0);
    const allLinks = host.savedLinks.flat();
    const teamMeeting = allLinks.find((l) => l.title === "Team Meeting");
    expect(teamMeeting).toBeDefined();
    expect(teamMeeting?.source).toBe("google-calendar:uid-1@google.com");
  });

  it("error path: clears state, releases lock, re-throws", async () => {
    const calendarId = "user@example.com";
    const state: SyncState = {
      calendarId,
      min: new Date("2024-01-01"),
      max: null,
      sequence: 1,
    };
    const host = makeFakeHost({ calendarId, initialState: state });

    // Stub fetch to throw
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new Error("Network failure");
      })
    );

    await expect(
      runSyncBatch(host, 1, "full", calendarId, false)
    ).rejects.toThrow("Network failure");

    // Lock released on error
    expect(host.releaseLockCalls).toContain(`sync_${calendarId}`);
    // sync_state cleared on error
    expect(host.store.has(`sync_state_${calendarId}`)).toBe(false);
  });
});

describe("runCalendarInit", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("returns { done: true } when token is missing", async () => {
    const host = makeFakeHost({ token: null });
    const result = await runCalendarInit(host, "primary");
    expect(result).toEqual({ done: true });
  });

  it("returns { done: true } when lock is not acquired", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    host.acquireLockResult = false;

    vi.stubGlobal(
      "fetch",
      vi.fn(async () => makeCalendarResponse(calendarId))
    );

    const result = await runCalendarInit(host, calendarId);
    expect(result).toEqual({ done: true });
  });

  it("resolves 'primary' and returns { next } with resolvedCalendarId", async () => {
    const resolvedId = "user@example.com";
    const host = makeFakeHost({ calendarId: resolvedId });

    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        if (url.includes("/calendars/primary")) {
          return makeCalendarResponse(resolvedId);
        }
        return makeCalendarResponse(resolvedId);
      })
    );

    const result = await runCalendarInit(host, "primary");

    expect("done" in result).toBe(false);
    if ("next" in result) {
      expect(result.next.resolvedCalendarId).toBe(resolvedId);
      expect(result.next.batchNumber).toBe(1);
      expect(result.next.mode).toBe("full");
      expect(result.next.initialSync).toBe(true);
    }

    // sync_state must be set with phase: "quick"
    const state = host.store.get(`sync_state_${resolvedId}`) as SyncState;
    expect(state.phase).toBe("quick");
  });
});

// ---------------------------------------------------------------------------
// Tests for new live-update / RSVP extracted functions
// ---------------------------------------------------------------------------

describe("startIncrementalSyncFn", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("returns { done: true } when lock is not acquired", async () => {
    const host = makeFakeHost();
    host.acquireLockResult = false;
    const result = await startIncrementalSyncFn(host, "user@example.com");
    expect(result).toEqual({ done: true });
  });

  it("returns { done: true } when no watch data is stored", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    // No calendar_watch_<id> stored → returns done
    const result = await startIncrementalSyncFn(host, calendarId);
    expect(result).toEqual({ done: true });
    // Lock released when watch data missing
    expect(host.releaseLockCalls).toContain(`sync_${calendarId}`);
  });

  it("returns { next: true } and stores incremental SyncState (with sync token)", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    host.store.set(`calendar_watch_${calendarId}`, {
      watchId: "wid",
      calendarId,
      secret: "s",
      expiry: new Date(Date.now() + 3600000).toISOString(),
    });
    host.store.set(`last_sync_token_${calendarId}`, "tok123");

    const result = await startIncrementalSyncFn(host, calendarId);
    expect(result).toEqual({ next: true });

    const state = host.store.get(`sync_state_${calendarId}`) as SyncState;
    expect(state.state).toBe("tok123");
    expect(state.calendarId).toBe(calendarId);
  });

  it("returns { next: true } and stores full-range SyncState (without sync token)", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    host.store.set(`calendar_watch_${calendarId}`, {
      watchId: "wid",
      calendarId,
      secret: "s",
      expiry: new Date(Date.now() + 3600000).toISOString(),
    });
    // No last_sync_token — falls back to 7-day window

    const result = await startIncrementalSyncFn(host, calendarId);
    expect(result).toEqual({ next: true });

    const state = host.store.get(`sync_state_${calendarId}`) as SyncState;
    expect(state.min).toBeInstanceOf(Date);
    expect(state.state).toBeUndefined();
  });
});

describe("validateCalendarWebhookFn", () => {
  it("returns { invalid: true } when required headers are missing", async () => {
    const host = makeFakeHost();
    const request = { method: "POST", headers: {}, params: {}, body: null };
    const result = await validateCalendarWebhookFn(host, request, "cal@example.com");
    expect(result).toEqual({ invalid: true });
  });

  it("returns { invalid: true } when watch data is missing", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    const request = {
      method: "POST",
      headers: {
        "x-goog-channel-id": "chan-123",
        "x-goog-channel-token": "secret=abc",
      },
      params: {},
      body: null,
    };
    const result = await validateCalendarWebhookFn(host, request, calendarId);
    expect(result).toEqual({ invalid: true });
  });

  it("returns { invalid: true } when secret does not match", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    host.store.set(`calendar_watch_${calendarId}`, {
      watchId: "chan-123",
      secret: "correct-secret",
      calendarId,
      expiry: new Date(Date.now() + 10 * 24 * 60 * 60 * 1000).toISOString(),
    });
    const request = {
      method: "POST",
      headers: {
        "x-goog-channel-id": "chan-123",
        "x-goog-channel-token": "secret=wrong-secret",
      },
      params: {},
      body: null,
    };
    const result = await validateCalendarWebhookFn(host, request, calendarId);
    expect(result).toEqual({ invalid: true });
  });

  it("returns { valid: true, needsRenewal: false } for a valid webhook far from expiry", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    const farFuture = new Date(Date.now() + 10 * 24 * 60 * 60 * 1000);
    host.store.set(`calendar_watch_${calendarId}`, {
      watchId: "chan-123",
      secret: "my-secret",
      calendarId,
      expiry: farFuture.toISOString(),
    });
    const request = {
      method: "POST",
      headers: {
        "x-goog-channel-id": "chan-123",
        "x-goog-channel-token": "secret=my-secret",
      },
      params: {},
      body: null,
    };
    const result = await validateCalendarWebhookFn(host, request, calendarId);
    expect(result).toEqual({ valid: true, needsRenewal: false });
  });

  it("returns { valid: true, needsRenewal: true } when watch expires within 24h", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    // Expiry is 12 hours from now — well within the 24h renewal window.
    const soon = new Date(Date.now() + 12 * 60 * 60 * 1000);
    host.store.set(`calendar_watch_${calendarId}`, {
      watchId: "chan-123",
      secret: "my-secret",
      calendarId,
      expiry: soon.toISOString(),
    });
    const request = {
      method: "POST",
      headers: {
        "x-goog-channel-id": "chan-123",
        "x-goog-channel-token": "secret=my-secret",
      },
      params: {},
      body: null,
    };
    const result = await validateCalendarWebhookFn(host, request, calendarId);
    expect(result).toEqual({ valid: true, needsRenewal: true });
  });
});

describe("getWatchRenewalScheduleFn", () => {
  it("returns null when no watch data exists", async () => {
    const host = makeFakeHost({ calendarId: "user@example.com" });
    const result = await getWatchRenewalScheduleFn(host, "user@example.com");
    expect(result).toBeNull();
  });

  it("returns { immediate: true } when renewal window has passed", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    // Expiry in 12h — renewal time would be 12h - 24h = -12h ago (immediate)
    const soonExpiry = new Date(Date.now() + 12 * 60 * 60 * 1000);
    host.store.set(`calendar_watch_${calendarId}`, {
      watchId: "w",
      secret: "s",
      calendarId,
      expiry: soonExpiry.toISOString(),
    });
    const result = await getWatchRenewalScheduleFn(host, calendarId);
    expect(result).toEqual({ immediate: true });
  });

  it("returns { firstRunAt, intervalMs } when renewal is in the future", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    // Expiry in 5 days: renewal time = 5d - 24h = 4 days from now (in the future)
    const farExpiry = new Date(Date.now() + 5 * 24 * 60 * 60 * 1000);
    host.store.set(`calendar_watch_${calendarId}`, {
      watchId: "w",
      secret: "s",
      calendarId,
      expiry: farExpiry.toISOString(),
    });
    const result = await getWatchRenewalScheduleFn(host, calendarId);
    expect(result).not.toBeNull();
    expect(result).not.toEqual({ immediate: true });
    if (result && "firstRunAt" in result) {
      expect(result.firstRunAt).toBeInstanceOf(Date);
      expect(result.intervalMs).toBe(3.5 * 24 * 60 * 60 * 1000);
      // firstRunAt should be approximately 4 days from now (5d - 24h)
      const expectedRenewal = farExpiry.getTime() - 24 * 60 * 60 * 1000;
      expect(result.firstRunAt.getTime()).toBeCloseTo(expectedRenewal, -3);
    }
  });
});

describe("extractRSVPParamsFn", () => {
  const makeThread = (meta: Record<string, unknown> | null): Thread =>
    ({ meta } as unknown as Thread);

  it("returns null when meta is absent", () => {
    const result = extractRSVPParamsFn(makeThread(null), "attend");
    expect(result).toBeNull();
  });

  it("returns null when eventId is absent", () => {
    const result = extractRSVPParamsFn(
      makeThread({ syncableId: "cal@example.com" }),
      "attend"
    );
    expect(result).toBeNull();
  });

  it("returns null when calendarId is absent", () => {
    const result = extractRSVPParamsFn(
      makeThread({ id: "evt123" }),
      "attend"
    );
    expect(result).toBeNull();
  });

  it("maps status=attend to googleStatus=accepted", () => {
    const result = extractRSVPParamsFn(
      makeThread({ syncableId: "cal@example.com", id: "evt-1" }),
      "attend"
    );
    expect(result).toEqual({
      calendarId: "cal@example.com",
      eventId: "evt-1",
      googleStatus: "accepted",
    });
  });

  it("maps status=skip to googleStatus=declined", () => {
    const result = extractRSVPParamsFn(
      makeThread({ syncableId: "cal@example.com", id: "evt-2" }),
      "skip"
    );
    expect(result).toEqual({
      calendarId: "cal@example.com",
      eventId: "evt-2",
      googleStatus: "declined",
    });
  });

  it("maps status=null to googleStatus=needsAction", () => {
    const result = extractRSVPParamsFn(
      makeThread({ syncableId: "cal@example.com", id: "evt-3" }),
      null
    );
    expect(result).toEqual({
      calendarId: "cal@example.com",
      eventId: "evt-3",
      googleStatus: "needsAction",
    });
  });
});

describe("updateEventRSVPWithApiFn", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("patches event attendees with new status", async () => {
    const calendarId = "user@example.com";
    const eventId = "event-abc";

    const event = {
      id: eventId,
      status: "confirmed" as const,
      attendees: [
        { email: "user@example.com", self: true, responseStatus: "needsAction" },
        { email: "other@example.com", responseStatus: "accepted" },
      ],
    };

    const fetchSpy = vi.fn(async (url: string, init?: RequestInit) => {
      if (url.includes(`/events/${eventId}`) && (!init?.method || init.method === "GET")) {
        return new Response(JSON.stringify(event), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      if (url.includes("calendarList/primary")) {
        return new Response(JSON.stringify({ id: calendarId }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      if (url.includes(`/events/${eventId}`) && init?.method === "PATCH") {
        return new Response(JSON.stringify({ ...event }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      throw new Error(`Unexpected fetch: ${url}`);
    });
    vi.stubGlobal("fetch", fetchSpy);

    const api = new GoogleApi("fake-token");
    await updateEventRSVPWithApiFn(api, calendarId, eventId, "accepted");

    // Find the PATCH call
    const patchCall = fetchSpy.mock.calls.find(
      ([url, init]) => typeof url === "string" && url.includes(`/events/${eventId}`) && init?.method === "PATCH"
    );
    expect(patchCall).toBeDefined();
    const patchBody = JSON.parse(patchCall![1]?.body as string);
    const selfAttendee = patchBody.attendees.find((a: { self?: boolean }) => a.self);
    expect(selfAttendee?.responseStatus).toBe("accepted");
  });

  it("is a no-op when status already matches", async () => {
    const calendarId = "user@example.com";
    const eventId = "event-xyz";

    const event = {
      id: eventId,
      status: "confirmed" as const,
      attendees: [
        { email: "user@example.com", self: true, responseStatus: "accepted" },
      ],
    };

    const fetchSpy = vi.fn(async (url: string, _init?: RequestInit) => {
      if (url.includes(`/events/${eventId}`)) {
        return new Response(JSON.stringify(event), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      if (url.includes("calendarList/primary")) {
        return new Response(JSON.stringify({ id: calendarId }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      throw new Error(`Unexpected fetch: ${url}`);
    });
    vi.stubGlobal("fetch", fetchSpy);

    const api = new GoogleApi("fake-token");
    await updateEventRSVPWithApiFn(api, calendarId, eventId, "accepted");

    // No PATCH should have been issued since status already matches
    const patchCall = fetchSpy.mock.calls.find(
      ([, init]) => init?.method === "PATCH"
    );
    expect(patchCall).toBeUndefined();
  });
});

describe("cancelEventWithApiFn", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("issues a DELETE against the event's own calendar/eventId", async () => {
    const calendarId = "user@example.com";
    const eventId = "event-abc";

    const fetchSpy = vi.fn(async (url: string, init?: RequestInit) => {
      if (
        url ===
          `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events/${eventId}` &&
        init?.method === "DELETE"
      ) {
        return new Response(null, { status: 204 });
      }
      throw new Error(`Unexpected fetch: ${url}`);
    });
    vi.stubGlobal("fetch", fetchSpy);

    const api = new GoogleApi("fake-token");
    await cancelEventWithApiFn(api, calendarId, eventId);

    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });

  it("is a no-op (doesn't throw) when the event is already gone", async () => {
    const calendarId = "user@example.com";
    const eventId = "event-already-deleted";

    const fetchSpy = vi.fn(async () => new Response(null, { status: 410 }));
    vi.stubGlobal("fetch", fetchSpy);

    const api = new GoogleApi("fake-token");
    await expect(
      cancelEventWithApiFn(api, calendarId, eventId)
    ).resolves.toBeUndefined();
  });
});

describe("setupCalendarWatchFn", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("returns { skipped: true } for localhost webhook URLs", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    const result = await setupCalendarWatchFn(
      host,
      "http://localhost:8787/hook/abc",
      calendarId
    );
    expect(result).toEqual({ skipped: true });
  });

  it("calls Google API and stores watch data on success", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });

    const expirationMs = (Date.now() + 7 * 24 * 60 * 60 * 1000).toString();
    vi.stubGlobal("fetch", vi.fn(async (url: string) => {
      if (url.includes("/watch")) {
        return new Response(
          JSON.stringify({ expiration: expirationMs, resourceId: "res-id" }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        );
      }
      // integrations.get for getApiFn — not called here since token is provided
      // calendarList/primary is NOT called by setupCalendarWatchFn itself
      throw new Error(`Unexpected fetch: ${url}`);
    }));

    const result = await setupCalendarWatchFn(
      host,
      "https://api.example.com/hook/abc",
      calendarId
    );

    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.expiry).toBeInstanceOf(Date);
    }

    const watchData = host.store.get(`calendar_watch_${calendarId}`) as Record<string, unknown>;
    expect(watchData).toBeDefined();
    expect(watchData.resourceId).toBe("res-id");
    expect(watchData.calendarId).toBe(calendarId);
  });
});

describe("stopCalendarWatchFn", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("is a no-op when no watch data exists", async () => {
    const host = makeFakeHost({ calendarId: "user@example.com" });
    // Should not throw and should not call fetch
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    await stopCalendarWatchFn(host, "user@example.com");
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("calls channels/stop when watch data exists", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    host.store.set(`calendar_watch_${calendarId}`, {
      watchId: "w-123",
      resourceId: "r-456",
      secret: "s",
      calendarId,
      expiry: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(),
    });

    vi.stubGlobal("fetch", vi.fn(async () =>
      new Response(null, { status: 204 })
    ));

    await stopCalendarWatchFn(host, calendarId);

    // Verify channels/stop was called
    const [url, init] = (vi.mocked(fetch).mock.calls[0] || []) as [string, RequestInit];
    expect(url).toContain("channels/stop");
    const body = JSON.parse(init?.body as string);
    expect(body.id).toBe("w-123");
    expect(body.resourceId).toBe("r-456");
  });
});

// ---------------------------------------------------------------------------
// Cancellations of events that were never imported (phantom-thread guard)
// ---------------------------------------------------------------------------

describe("processCalendarEventsFn — stale cancellations", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("drops a cancellation whose event was last modified before the first sync", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    // This connector first synced the calendar on 2026-06-25.
    host.store.set(
      `first_sync_at_${calendarId}`,
      new Date("2026-06-25T00:00:00.000Z").toISOString()
    );
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    // A 3-year-old recurring master that has been cancelled in Google since
    // 2023 (event.updated predates our first sync) leaks through the
    // incremental syncToken's showDeleted results. We never imported it, so
    // there is no thread to cancel — emitting a link would be a phantom.
    const staleCancelled = {
      id: "evt-stale",
      iCalUID: "70hj@google.com",
      status: "cancelled" as const,
      created: "2023-05-09T14:34:19.000Z",
      updated: "2023-08-04T14:27:58.535Z",
      summary: "Product 0->1",
    };

    await processCalendarEventsFn(host, [staleCancelled], calendarId, false);

    expect(host.savedLinks.flat()).toHaveLength(0);
  });

  it("keeps a cancellation whose event was modified after the first sync", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    host.store.set(
      `first_sync_at_${calendarId}`,
      new Date("2026-06-25T00:00:00.000Z").toISOString()
    );
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    // An upcoming event we imported, then cancelled after we started syncing.
    // Use a future start/end so this stays a "keep" case regardless of when the
    // test runs (a past event would be dropped by the past-cancellation guard).
    const futureStart = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);
    const freshCancelled = {
      id: "evt-fresh",
      iCalUID: "abc@google.com",
      status: "cancelled" as const,
      created: "2026-06-01T10:00:00.000Z",
      updated: "2026-06-26T12:00:00.000Z",
      start: { dateTime: futureStart.toISOString() },
      end: {
        dateTime: new Date(
          futureStart.getTime() + 60 * 60 * 1000
        ).toISOString(),
      },
      summary: "Team sync",
    };

    await processCalendarEventsFn(host, [freshCancelled], calendarId, false);

    const saved = host.savedLinks.flat();
    expect(saved).toHaveLength(1);
    expect(
      saved[0].notes?.some(
        (n) => (n as { key?: string }).key === "cancellation"
      )
    ).toBe(true);
  });

  it("drops a cancellation for an event older than the history window when no first-sync marker exists", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    // No first_sync_at marker (connector instance predates the marker).
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    const oldCancelled = {
      id: "evt-old-nomarker",
      iCalUID: "old@google.com",
      status: "cancelled" as const,
      created: "2023-05-09T14:34:19.000Z",
      updated: "2023-08-04T14:27:58.535Z",
      summary: "Product 0->1",
    };

    await processCalendarEventsFn(host, [oldCancelled], calendarId, false);

    expect(host.savedLinks.flat()).toHaveLength(0);
  });
});

describe("prepareEventInstanceFn — stale occurrence cancellations", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("drops a cancelled recurring occurrence older than the history window", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    // A cancelled occurrence of a recurring master, whose occurrence date is
    // years before the import window — never imported, so it must not create
    // a phantom thread.
    const staleOccurrence = {
      id: "evt-occ-stale",
      iCalUID: "master@google.com",
      recurringEventId: "masterid",
      originalStartTime: { dateTime: "2023-08-04T14:27:58.000Z" },
      status: "cancelled" as const,
      updated: "2023-08-05T00:00:00.000Z",
    };

    await processCalendarEventsFn(host, [staleOccurrence], calendarId, false);

    expect(host.savedLinks.flat()).toHaveLength(0);
  });

  it("keeps a cancelled recurring occurrence within the window modified after first sync", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    host.store.set(
      `first_sync_at_${calendarId}`,
      new Date("2026-06-25T00:00:00.000Z").toISOString()
    );
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    // Future occurrence so this stays a "keep" case regardless of run date.
    const freshOccurrence = {
      id: "evt-occ-fresh",
      iCalUID: "master2@google.com",
      recurringEventId: "masterid2",
      originalStartTime: {
        dateTime: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(),
      },
      status: "cancelled" as const,
      updated: "2026-06-26T12:00:00.000Z",
    };

    await processCalendarEventsFn(host, [freshOccurrence], calendarId, false);

    const saved = host.savedLinks.flat();
    expect(saved).toHaveLength(1);
    expect(
      saved[0].notes?.some((n) =>
        (n as { key?: string }).key?.startsWith("cancellation-")
      )
    ).toBe(true);
  });
});

describe("processCalendarEventsFn — past cancellations", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  const isoDaysFromNow = (n: number) =>
    new Date(Date.now() + n * 24 * 60 * 60 * 1000).toISOString();
  const dateDaysFromNow = (n: number) =>
    new Date(Date.now() + n * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);

  it("drops a cancelled standalone event that has already ended", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    // Synced a month ago; the event was imported then cancelled — but it has
    // already happened, so surfacing the cancellation only flips unread noise.
    host.store.set(`first_sync_at_${calendarId}`, isoDaysFromNow(-30));
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    const pastCancelled = {
      id: "evt-past",
      iCalUID: "past@google.com",
      status: "cancelled" as const,
      created: isoDaysFromNow(-10),
      updated: isoDaysFromNow(-1), // recent edit, so the unimported guard keeps it
      start: { dateTime: isoDaysFromNow(-2) },
      end: { dateTime: isoDaysFromNow(-2) }, // ended ~2 days ago
      summary: "Old standup",
    };

    await processCalendarEventsFn(host, [pastCancelled], calendarId, false);

    expect(host.savedLinks.flat()).toHaveLength(0);
  });

  it("keeps a cancelled standalone event that has started but not finished", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    host.store.set(`first_sync_at_${calendarId}`, isoDaysFromNow(-30));
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    const ongoingCancelled = {
      id: "evt-ongoing",
      iCalUID: "ongoing@google.com",
      status: "cancelled" as const,
      created: isoDaysFromNow(-10),
      updated: isoDaysFromNow(0),
      start: { dateTime: isoDaysFromNow(-1) }, // started yesterday
      end: { dateTime: isoDaysFromNow(1) }, // ends tomorrow — still running
      summary: "Multi-day workshop",
    };

    await processCalendarEventsFn(host, [ongoingCancelled], calendarId, false);

    const saved = host.savedLinks.flat();
    expect(saved).toHaveLength(1);
    expect(
      saved[0].notes?.some(
        (n) => (n as { key?: string }).key === "cancellation"
      )
    ).toBe(true);
  });

  it("keeps a cancelled standalone event in the future", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    host.store.set(`first_sync_at_${calendarId}`, isoDaysFromNow(-30));
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    const futureCancelled = {
      id: "evt-future",
      iCalUID: "future@google.com",
      status: "cancelled" as const,
      created: isoDaysFromNow(-10),
      updated: isoDaysFromNow(-1),
      start: { dateTime: isoDaysFromNow(7) },
      end: { dateTime: isoDaysFromNow(7) },
      summary: "Upcoming review",
    };

    await processCalendarEventsFn(host, [futureCancelled], calendarId, false);

    expect(host.savedLinks.flat()).toHaveLength(1);
  });

  it("drops a cancelled recurring occurrence whose occurrence is in the past", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    host.store.set(`first_sync_at_${calendarId}`, isoDaysFromNow(-60));
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    // Mirrors the prod bug: a recurring occurrence cancelled ~weeks after it
    // already happened. originalStartTime is within the 2-year history window
    // and updated is recent (so the unimported guard keeps it), but the
    // occurrence is fully in the past — surfacing it just flips unread noise.
    const pastOccurrence = {
      id: "evt-occ-past",
      iCalUID: "recurring@google.com",
      recurringEventId: "recurringid",
      originalStartTime: { dateTime: isoDaysFromNow(-30) },
      status: "cancelled" as const,
      updated: isoDaysFromNow(-1),
    };

    await processCalendarEventsFn(host, [pastOccurrence], calendarId, false);

    expect(host.savedLinks.flat()).toHaveLength(0);
  });

  it("keeps a cancelled all-day recurring occurrence happening today", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    host.store.set(`first_sync_at_${calendarId}`, isoDaysFromNow(-60));
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    // An all-day occurrence carries only a date (no time). Today's all-day
    // event has started but not finished — it runs until end of day — so its
    // cancellation must still surface.
    const todayAllDay = {
      id: "evt-occ-allday-today",
      iCalUID: "recurring-allday@google.com",
      recurringEventId: "recurringid-allday",
      originalStartTime: { date: dateDaysFromNow(0) },
      status: "cancelled" as const,
      updated: isoDaysFromNow(0),
    };

    await processCalendarEventsFn(host, [todayAllDay], calendarId, false);

    const saved = host.savedLinks.flat();
    expect(saved).toHaveLength(1);
    expect(
      saved[0].notes?.some((n) =>
        (n as { key?: string }).key?.startsWith("cancellation-")
      )
    ).toBe(true);
  });
});

describe("processCalendarEventsFn — re-confirmation after cancellation", () => {
  const iso = (n: number) =>
    new Date(Date.now() + n * 24 * 60 * 60 * 1000).toISOString();

  it("un-archives the base schedule and clears the cancellation note when a cancelled event returns confirmed", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    // Calendar has been synced for a while, so the cancellation is not treated
    // as an unimported/never-seen event.
    host.store.set(`first_sync_at_${calendarId}`, iso(-60));
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    const iCalUID = "aqua@google.com";
    const canonical = `google-calendar:${iCalUID}`;
    const start = { dateTime: iso(30) };
    const end = { dateTime: iso(30.5) }; // future — cancellation must surface

    // 1) Google reports the recurring master as cancelled (incremental sync).
    const cancelled = {
      id: "aqua-master",
      iCalUID,
      status: "cancelled" as const,
      summary: "Aqua fit",
      start,
      end,
      updated: iso(-1),
    };
    await processCalendarEventsFn(host, [cancelled], calendarId, false);

    const cancelLink = host.savedLinks
      .flat()
      .find((l) => l.source === canonical);
    expect(cancelLink?.schedules?.[0]).toMatchObject({ archived: true });
    expect(
      cancelLink?.notes?.some(
        (n) => (n as { key?: string }).key === "cancellation"
      )
    ).toBe(true);
    expect(host.store.get(`cancel_seen:${canonical}`)).toBeTruthy();

    // 2) Google now reports the same master as confirmed (incremental sync).
    const confirmed = {
      id: "aqua-master",
      iCalUID,
      status: "confirmed" as const,
      summary: "Aqua fit",
      start,
      end,
      recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=SU;COUNT=7"],
    };
    await processCalendarEventsFn(host, [confirmed], calendarId, false);

    const confirmLink = [...host.savedLinks.flat()]
      .reverse()
      .find((l) => l.source === canonical);
    expect(confirmLink?.schedules?.length).toBeGreaterThan(0);
    // Every schedule the confirmed sync emits must be explicitly un-archived,
    // so the app stops treating the series as cancelled.
    for (const s of confirmLink!.schedules!) {
      expect((s as { archived?: boolean }).archived).toBe(false);
    }
    // The stale "This event was cancelled." note must be archived.
    const cancelNote = confirmLink?.notes?.find(
      (n) => (n as { key?: string }).key === "cancellation"
    );
    expect(cancelNote).toBeDefined();
    expect((cancelNote as { archived?: boolean }).archived).toBe(true);
    // Marker cleared so the reversal doesn't repeat on every subsequent sync.
    expect(host.store.get(`cancel_seen:${canonical}`)).toBeFalsy();
  });

  it("does not emit a spurious cancellation note for a normal confirmed event", async () => {
    const calendarId = "user@example.com";
    const host = makeFakeHost({ calendarId });
    host.store.set(`first_sync_at_${calendarId}`, iso(-60));
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    const confirmed = {
      id: "plain",
      iCalUID: "plain@google.com",
      status: "confirmed" as const,
      summary: "Standup",
      start: { dateTime: iso(1) },
      end: { dateTime: iso(1.05) },
    };
    await processCalendarEventsFn(host, [confirmed], calendarId, false);

    const link = host.savedLinks
      .flat()
      .find((l) => l.source === "google-calendar:plain@google.com");
    expect(link).toBeDefined();
    expect(
      link?.notes?.some((n) => (n as { key?: string }).key === "cancellation")
    ).toBe(false);
  });
});

describe("cancellationWasSelfInitiatedFn", () => {
  it("treats a cancellation the user organized as self-initiated", () => {
    expect(
      cancellationWasSelfInitiatedFn({
        id: "e",
        status: "cancelled",
        organizer: { email: "user@example.com", self: true },
      })
    ).toBe(true);
  });

  it("does not treat a cancellation someone else organized as self-initiated", () => {
    // Even when the user is the only attendee shown, a non-self organizer means
    // someone else could have cancelled it — the user should still be notified.
    expect(
      cancellationWasSelfInitiatedFn({
        id: "e",
        status: "cancelled",
        organizer: { email: "boss@example.com", self: false },
        attendees: [{ email: "user@example.com", self: true }],
      })
    ).toBe(false);
  });

  it("treats a solo event (user the only invitee) as self-initiated", () => {
    expect(
      cancellationWasSelfInitiatedFn({
        id: "e",
        status: "cancelled",
        attendees: [{ email: "user@example.com", self: true }],
      })
    ).toBe(true);
  });

  it("does not treat an event with other invitees as self-initiated", () => {
    expect(
      cancellationWasSelfInitiatedFn({
        id: "e",
        status: "cancelled",
        attendees: [
          { email: "user@example.com", self: true },
          { email: "other@example.com" },
        ],
      })
    ).toBe(false);
  });

  it("does not conclude self-initiated from a sparse payload (no organizer or attendees)", () => {
    // Google only guarantees id/status/updated on a cancelled event. Absence of
    // attendees is "unknown", not "solo" — never suppress on missing data.
    expect(
      cancellationWasSelfInitiatedFn({ id: "e", status: "cancelled" })
    ).toBe(false);
  });
});

describe("processCalendarEventsFn — self-initiated cancellations", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  const calendarId = "user@example.com";
  const futureStart = () => new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);

  function seedHost() {
    const host = makeFakeHost({ calendarId });
    host.store.set(
      `first_sync_at_${calendarId}`,
      new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString()
    );
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));
    return host;
  }

  it("marks a standalone cancellation the user organized as read", async () => {
    const host = seedHost();
    const start = futureStart();
    const event = {
      id: "evt-self",
      iCalUID: "self@google.com",
      status: "cancelled" as const,
      updated: new Date().toISOString(),
      start: { dateTime: start.toISOString() },
      end: { dateTime: new Date(start.getTime() + 3_600_000).toISOString() },
      summary: "Kia AC",
      organizer: { email: "user@example.com", self: true },
    };

    await processCalendarEventsFn(host, [event], calendarId, false);

    const saved = host.savedLinks.flat();
    expect(saved).toHaveLength(1);
    // Still records the cancellation (archives the schedule + note) …
    expect(
      saved[0].notes?.some((n) => (n as { key?: string }).key === "cancellation")
    ).toBe(true);
    // … but does not flip the thread unread for the user who deleted it.
    expect(saved[0].unread).toBe(false);
  });

  it("keeps a standalone cancellation someone else organized unread", async () => {
    const host = seedHost();
    const start = futureStart();
    const event = {
      id: "evt-other",
      iCalUID: "other@google.com",
      status: "cancelled" as const,
      updated: new Date().toISOString(),
      start: { dateTime: start.toISOString() },
      end: { dateTime: new Date(start.getTime() + 3_600_000).toISOString() },
      summary: "Team meeting",
      organizer: { email: "boss@example.com", self: false },
      attendees: [
        { email: "user@example.com", self: true },
        { email: "boss@example.com", organizer: true },
      ],
    };

    await processCalendarEventsFn(host, [event], calendarId, false);

    const saved = host.savedLinks.flat();
    expect(saved).toHaveLength(1);
    expect(saved[0].unread).toBeUndefined();
  });

  it("marks a self-organized recurring occurrence cancellation read", async () => {
    const host = seedHost();
    const start = futureStart();
    const event = {
      id: "evt-occ-self",
      iCalUID: "occ@google.com",
      recurringEventId: "master-self",
      originalStartTime: { dateTime: start.toISOString() },
      status: "cancelled" as const,
      updated: new Date().toISOString(),
      start: { dateTime: start.toISOString() },
      end: { dateTime: new Date(start.getTime() + 3_600_000).toISOString() },
      organizer: { email: "user@example.com", self: true },
    };

    await processCalendarEventsFn(host, [event], calendarId, false);

    const saved = host.savedLinks.flat();
    expect(saved).toHaveLength(1);
    expect(saved[0].unread).toBe(false);
  });
});

describe("processCalendarEventsFn — message-model note audiences", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  const calendarId = "user@example.com";
  const isoDaysFromNow = (n: number) =>
    new Date(Date.now() + n * 24 * 60 * 60 * 1000).toISOString();

  it("event notes carry accessContacts = attendees (message-model roster)", async () => {
    const host = makeFakeHost({ calendarId });
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    const event = {
      id: "e1",
      iCalUID: "uid-1",
      status: "confirmed" as const,
      summary: "Sync",
      description: "Agenda here",
      organizer: { email: "org@x.com", displayName: "Org" },
      attendees: [
        {
          email: "org@x.com",
          organizer: true,
          responseStatus: "accepted" as const,
        },
        { email: "bob@x.com", responseStatus: "needsAction" as const },
      ],
      start: { dateTime: isoDaysFromNow(1) },
      end: { dateTime: isoDaysFromNow(1) },
    };

    await processCalendarEventsFn(host, [event], calendarId, false);

    const link = host.savedLinks
      .flat()
      .find((l) => l.source === "google-calendar:uid-1");
    expect(link?.meta?.iCalUID).toBe("uid-1");

    const desc = link?.notes?.find((n) =>
      (n as { key?: string }).key?.startsWith("description-")
    );
    const emails = (
      (desc as { accessContacts?: Array<{ email?: string }> })
        .accessContacts ?? []
    )
      .map((c) => c.email)
      .sort();
    expect(emails).toEqual(["bob@x.com", "org@x.com"]);
  });

  it("cancellation-path link carries accessContacts, private access, author, and iCalUID meta", async () => {
    const host = makeFakeHost({ calendarId });
    host.store.set(`first_sync_at_${calendarId}`, isoDaysFromNow(-30));
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    const event = {
      id: "e2",
      iCalUID: "uid-2",
      status: "cancelled" as const,
      summary: "Standup",
      organizer: { email: "org@x.com", displayName: "Org" },
      attendees: [
        { email: "org@x.com", organizer: true },
        { email: "bob@x.com" },
      ],
      updated: isoDaysFromNow(0),
      start: { dateTime: isoDaysFromNow(1) },
      end: { dateTime: isoDaysFromNow(1) },
    };

    await processCalendarEventsFn(host, [event], calendarId, false);

    const link = host.savedLinks
      .flat()
      .find((l) => l.source === "google-calendar:uid-2");
    expect(link?.meta?.iCalUID).toBe("uid-2");
    expect(link?.access).toBe("private");
    expect(link?.author).toEqual({ email: "org@x.com", name: "Org" });

    const emails = (
      (link?.accessContacts ?? []) as Array<{ email?: string }>
    )
      .map((c) => c.email)
      .sort();
    expect(emails).toEqual(["bob@x.com", "org@x.com"]);
  });
});

// ---------------------------------------------------------------------------
// Event link priority — the calendar event link must always outrank a
// bundled email link (which defaults to priority 0), so the thread keeps
// rendering as an event even after email replies bundle onto it.
// ---------------------------------------------------------------------------

describe("processCalendarEventsFn — event link priority", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  const calendarId = "user@example.com";
  const isoDaysFromNow = (n: number) =>
    new Date(Date.now() + n * 24 * 60 * 60 * 1000).toISOString();

  it("floors priority at 1 for an event where the user is neither organizer nor attendee", async () => {
    const host = makeFakeHost({ calendarId });
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    const event = {
      id: "e1",
      iCalUID: "uid-1",
      status: "confirmed" as const,
      summary: "X",
      organizer: { email: "o@x" },
      attendees: [],
      start: { dateTime: isoDaysFromNow(1) },
      end: { dateTime: isoDaysFromNow(1) },
    };

    await processCalendarEventsFn(host, [event], calendarId, false);

    const link = host.savedLinks
      .flat()
      .find((l) => l.source === "google-calendar:uid-1");
    expect(link?.priority).toBe(1);
  });

  it("gives organizer events priority 100", async () => {
    const host = makeFakeHost({ calendarId });
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    const event = {
      id: "e2",
      iCalUID: "uid-organizer",
      status: "confirmed" as const,
      summary: "Organized by me",
      organizer: { email: "me@x.com", self: true },
      attendees: [{ email: "me@x.com", self: true, organizer: true }],
      start: { dateTime: isoDaysFromNow(1) },
      end: { dateTime: isoDaysFromNow(1) },
    };

    await processCalendarEventsFn(host, [event], calendarId, false);

    const link = host.savedLinks
      .flat()
      .find((l) => l.source === "google-calendar:uid-organizer");
    expect(link?.priority).toBe(100);
  });

  it("gives attendee (non-organizer) events priority 50", async () => {
    const host = makeFakeHost({ calendarId });
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    const event = {
      id: "e3",
      iCalUID: "uid-attendee",
      status: "confirmed" as const,
      summary: "Invited",
      organizer: { email: "boss@x.com", self: false },
      attendees: [
        { email: "boss@x.com", organizer: true },
        { email: "me@x.com", self: true },
      ],
      start: { dateTime: isoDaysFromNow(1) },
      end: { dateTime: isoDaysFromNow(1) },
    };

    await processCalendarEventsFn(host, [event], calendarId, false);

    const link = host.savedLinks
      .flat()
      .find((l) => l.source === "google-calendar:uid-attendee");
    expect(link?.priority).toBe(50);
  });

  it("floors priority at 1 on the cancellation-path link too", async () => {
    const host = makeFakeHost({ calendarId });
    host.store.set(`first_sync_at_${calendarId}`, isoDaysFromNow(-30));
    vi.stubGlobal("fetch", vi.fn(async () => makeEventsResponse([])));

    const event = {
      id: "e4",
      iCalUID: "uid-cancelled",
      status: "cancelled" as const,
      summary: "Cancelled, not mine",
      organizer: { email: "o@x" },
      attendees: [],
      updated: isoDaysFromNow(0),
      start: { dateTime: isoDaysFromNow(1) },
      end: { dateTime: isoDaysFromNow(1) },
    };

    await processCalendarEventsFn(host, [event], calendarId, false);

    const link = host.savedLinks
      .flat()
      .find((l) => l.source === "google-calendar:uid-cancelled");
    expect(link?.priority).toBe(1);
  });
});
