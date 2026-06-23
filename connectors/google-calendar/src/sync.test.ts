/**
 * Unit tests for runSyncBatch and runCalendarInit.
 *
 * Tests use a fake CalendarSyncHost that stubs out all tool access so no real
 * network or storage is needed. Fetch is stubbed for GoogleApi calls.
 */

import { afterEach, describe, expect, it, vi } from "vitest";
import type { NewLinkWithNotes } from "@plotday/twister";
import type { CalendarSyncHost } from "./sync";
import { runCalendarInit, runSyncBatch } from "./sync";
import type { SyncState } from "./google-api";

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
