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
  extractRSVPParamsFn,
  getWatchRenewalScheduleFn,
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
