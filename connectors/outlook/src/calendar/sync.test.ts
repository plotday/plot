/**
 * Unit tests for processOutlookEventsFn's message-model note/link audiences.
 *
 * Tests use a fake OutlookCalendarSyncHost that stubs out all tool access so
 * no real network or storage is needed.
 */

import { afterEach, describe, expect, it, vi } from "vitest";
import type { NewLinkWithNotes } from "@plotday/twister";
import type { OutlookCalendarSyncHost } from "./sync";
import { processOutlookEventsFn } from "./sync";
import type { OutlookEvent } from "./graph-api";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Build a minimal fake OutlookCalendarSyncHost backed by an in-memory store.
 * Mirrors google-calendar's makeFakeHost, minus googleContacts (Outlook has
 * no equivalent), and saveLinks resolves `Promise<unknown>` per
 * OutlookCalendarSyncHost's interface.
 */
function makeFakeHost(overrides?: {
  token?: { token: string; scopes: string[] } | null;
}): OutlookCalendarSyncHost & {
  store: Map<string, unknown>;
  savedLinks: NewLinkWithNotes[][];
  syncCompletedCalls: string[];
  releaseLockCalls: string[];
} {
  const storeMap = new Map<string, unknown>();
  const savedLinks: NewLinkWithNotes[][] = [];
  const syncCompletedCalls: string[] = [];
  const releaseLockCalls: string[] = [];

  const tokenValue =
    overrides?.token !== undefined
      ? overrides.token
      : { token: "fake-access-token", scopes: [] };

  const host: ReturnType<typeof makeFakeHost> = {
    store: storeMap,
    savedLinks,
    syncCompletedCalls,
    releaseLockCalls,

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
        saveLinks: async (links): Promise<unknown> => {
          savedLinks.push(links);
          return undefined;
        },
        channelSyncCompleted: async (channelId) => {
          syncCompletedCalls.push(channelId);
        },
      },
      store: {
        acquireLock: async (_key, _ttlMs) => true,
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

const isoDaysFromNow = (n: number) =>
  new Date(Date.now() + n * 24 * 60 * 60 * 1000).toISOString();

/**
 * Minimal OutlookEvent factory. Fills in the required `id`/`start`/`end`
 * fields with sane defaults so tests only need to specify what they care
 * about.
 */
function outlookEventFixture(partial: Partial<OutlookEvent>): OutlookEvent {
  return {
    id: "e1",
    start: { dateTime: isoDaysFromNow(1), timeZone: "UTC" },
    end: { dateTime: isoDaysFromNow(1), timeZone: "UTC" },
    ...partial,
  } as OutlookEvent;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("processOutlookEventsFn — message-model note/link audiences", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  const calendarId = "cal-1";

  it("event description note carries accessContacts = attendees", async () => {
    const host = makeFakeHost();

    await processOutlookEventsFn(
      host,
      [
        outlookEventFixture({
          id: "e1",
          iCalUId: "uid-1",
          subject: "Sync",
          body: { contentType: "text", content: "Agenda" },
          organizer: { emailAddress: { address: "org@x.com", name: "Org" } },
          attendees: [
            {
              emailAddress: { address: "org@x.com" },
              type: "required",
            },
            {
              emailAddress: { address: "bob@x.com" },
              type: "required",
            },
          ],
        }),
      ],
      calendarId,
      false
    );

    const link = host.savedLinks
      .flat()
      .find((l) => l.source === `outlook-calendar:${calendarId}:e1`);
    expect(link?.meta?.iCalUId).toBe("uid-1");

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
    // The description note is authored by the organizer, not the connection.
    expect((desc as { author?: { email?: string } }).author?.email).toBe(
      "org@x.com"
    );
  });

  it("dedupes the organizer when they're also listed as an attendee", async () => {
    const host = makeFakeHost();

    await processOutlookEventsFn(
      host,
      [
        outlookEventFixture({
          id: "e1",
          organizer: { emailAddress: { address: "org@x.com", name: "Org" } },
          attendees: [
            {
              emailAddress: { address: "ORG@x.com", name: "Organizer" },
              type: "required",
            },
            { emailAddress: { address: "bob@x.com" }, type: "required" },
          ],
        }),
      ],
      calendarId,
      false
    );

    const link = host.savedLinks
      .flat()
      .find((l) => l.source === `outlook-calendar:${calendarId}:e1`);
    const emails = (
      (link?.accessContacts ?? []) as Array<{ email?: string }>
    ).map((c) => c.email?.toLowerCase());
    expect(emails).toEqual(["org@x.com", "bob@x.com"]);
  });

  it("cancellation (@removed) link/note carry accessContacts when attendee data is present", async () => {
    const host = makeFakeHost();

    await processOutlookEventsFn(
      host,
      [
        outlookEventFixture({
          id: "e2",
          "@removed": { reason: "deleted" },
          organizer: { emailAddress: { address: "org@x.com", name: "Org" } },
          attendees: [
            { emailAddress: { address: "org@x.com" }, type: "required" },
            { emailAddress: { address: "bob@x.com" }, type: "required" },
          ],
        }),
      ],
      calendarId,
      false
    );

    const link = host.savedLinks
      .flat()
      .find((l) => l.source === `outlook-calendar:${calendarId}:e2`);
    expect(link?.access).toBe("private");
    const linkEmails = (
      (link?.accessContacts ?? []) as Array<{ email?: string }>
    )
      .map((c) => c.email)
      .sort();
    expect(linkEmails).toEqual(["bob@x.com", "org@x.com"]);
    // The cancellation link is authored by the organizer, not the connection.
    expect((link as { author?: { email?: string } }).author?.email).toBe(
      "org@x.com"
    );

    const cancelNote = link?.notes?.find(
      (n) => (n as { key?: string }).key === "cancellation"
    );
    const noteEmails = (
      (cancelNote as { accessContacts?: Array<{ email?: string }> })
        .accessContacts ?? []
    )
      .map((c) => c.email)
      .sort();
    expect(noteEmails).toEqual(["bob@x.com", "org@x.com"]);
  });

  it("cancellation (@removed) with no attendee data omits accessContacts (guard)", async () => {
    const host = makeFakeHost();

    await processOutlookEventsFn(
      host,
      [
        outlookEventFixture({
          id: "e3",
          start: undefined as unknown as OutlookEvent["start"],
          end: undefined as unknown as OutlookEvent["end"],
          "@removed": { reason: "deleted" },
        }),
      ],
      calendarId,
      false
    );

    const link = host.savedLinks
      .flat()
      .find((l) => l.source === `outlook-calendar:${calendarId}:e3`);
    expect(link?.access).toBeUndefined();
    expect(link?.accessContacts).toBeUndefined();

    const cancelNote = link?.notes?.find(
      (n) => (n as { key?: string }).key === "cancellation"
    );
    expect(
      (cancelNote as { accessContacts?: unknown }).accessContacts
    ).toBeUndefined();
  });
});

describe("processOutlookEventsFn — prefers the cancellation email over the generic note", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  const calendarId = "cal-1";

  it("skips the generic cancellation note when a cancel email is present", async () => {
    const host = makeFakeHost();
    host.readMailState = async <T>(key: string) =>
      (key === "cancel-email:uid-1" ? ({ at: "now" } as T) : null);

    await processOutlookEventsFn(
      host,
      [
        outlookEventFixture({
          id: "e1",
          iCalUId: "uid-1",
          "@removed": { reason: "deleted" },
          organizer: { emailAddress: { address: "org@x.com", name: "Org" } },
          attendees: [
            { emailAddress: { address: "org@x.com" }, type: "required" },
          ],
        }),
      ],
      calendarId,
      false
    );

    const link = host.savedLinks
      .flat()
      .find((l) => l.source === `outlook-calendar:${calendarId}:e1`);
    expect(link).toBeDefined();
    expect(
      link?.notes?.some((n) => (n as { key?: string }).key === "cancellation")
    ).toBe(false);
    // Structural cancellation (title/preview) still applies regardless of
    // the email marker.
    expect(link?.title).toBe("Cancelled Event");
    expect(link?.preview).toBe("Cancelled");
  });

  it("keeps the generic cancellation note when no cancel email marker exists", async () => {
    const host = makeFakeHost();
    // No readMailState set on this host at all (mirrors hosts/tests that
    // predate the mail/calendar wiring) — must behave exactly as before.

    await processOutlookEventsFn(
      host,
      [
        outlookEventFixture({
          id: "e2",
          iCalUId: "uid-2",
          "@removed": { reason: "deleted" },
        }),
      ],
      calendarId,
      false
    );

    const link = host.savedLinks
      .flat()
      .find((l) => l.source === `outlook-calendar:${calendarId}:e2`);
    expect(link).toBeDefined();
    expect(
      link?.notes?.some((n) => (n as { key?: string }).key === "cancellation")
    ).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Event link priority — the calendar event link must always outrank a
// bundled email link (which defaults to priority 0), so the thread keeps
// rendering as an event even after email replies bundle onto it. Outlook's
// Graph event payload carries no reliable self/organizer signal (no
// `isOrganizer` boolean, no per-attendee `self` flag), so both the main
// event link and the cancellation-path link use a constant floor.
// ---------------------------------------------------------------------------

describe("processOutlookEventsFn — event link priority", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  const calendarId = "cal-1";

  it("gives the main event link priority >= 1", async () => {
    const host = makeFakeHost();

    await processOutlookEventsFn(
      host,
      [
        outlookEventFixture({
          id: "e1",
          iCalUId: "uid-1",
          subject: "Sync",
          organizer: { emailAddress: { address: "org@x.com", name: "Org" } },
          attendees: [
            { emailAddress: { address: "bob@x.com" }, type: "required" },
          ],
        }),
      ],
      calendarId,
      false
    );

    const link = host.savedLinks
      .flat()
      .find((l) => l.source === `outlook-calendar:${calendarId}:e1`);
    expect(link?.priority).toBeGreaterThanOrEqual(1);
  });

  it("gives the cancellation-path link priority >= 1", async () => {
    const host = makeFakeHost();

    await processOutlookEventsFn(
      host,
      [
        outlookEventFixture({
          id: "e2",
          "@removed": { reason: "deleted" },
          organizer: { emailAddress: { address: "org@x.com", name: "Org" } },
          attendees: [
            { emailAddress: { address: "bob@x.com" }, type: "required" },
          ],
        }),
      ],
      calendarId,
      false
    );

    const link = host.savedLinks
      .flat()
      .find((l) => l.source === `outlook-calendar:${calendarId}:e2`);
    expect(link?.priority).toBeGreaterThanOrEqual(1);
  });

  it("floors the coalesced priority when a recurring instance is merged before its master in the same batch", async () => {
    // Regression test: addLink() coalesces same-source links within one
    // sync batch but previously didn't propagate `priority`. Recurring
    // instance/exception links never set `priority` at all, so when an
    // instance is processed (and becomes the batch's `existing` entry)
    // before its master arrives, the merge left `existing.priority`
    // `undefined` (-> server default 0) even though the master carries a
    // constant floor of 1 — letting a bundled email tie/win primacy
    // depending on event-vs-instance ordering within the page.
    const host = makeFakeHost();

    const instance = outlookEventFixture({
      id: "instance-1",
      type: "occurrence",
      seriesMasterId: "master-1",
      originalStart: isoDaysFromNow(2),
    });

    const master = outlookEventFixture({
      id: "master-1",
      subject: "Recurring sync",
      organizer: { emailAddress: { address: "org@x.com", name: "Org" } },
      attendees: [
        { emailAddress: { address: "bob@x.com" }, type: "required" },
      ],
    });

    // Instance BEFORE master, in one batch — the exact ordering that
    // previously dropped the priority floor.
    await processOutlookEventsFn(
      host,
      [instance, master],
      calendarId,
      false
    );

    const saved = host.savedLinks.flat();
    const masterSource = `outlook-calendar:${calendarId}:master-1`;
    // Coalesced onto a single link, not two.
    expect(saved.filter((l) => l.source === masterSource)).toHaveLength(1);

    const link = saved.find((l) => l.source === masterSource);
    expect(link?.priority).toBeGreaterThanOrEqual(1);
  });
});
