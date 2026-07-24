import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

import { Apple } from "../apple";
import type { CalDAVEvent } from "./caldav";
import type { ICSEvent } from "./ics-parser";
import type { NewLinkWithNotes } from "@plotday/twister";

/**
 * Coverage for the master/occurrence transform in `apple.ts`
 * (`processCalDAVEvents`, `prepareEvent`, `prepareEventInstance`, and the
 * `pending_occ:`/`seen_master:` cross-batch buffering in `finishSync`) — see
 * the task brief: this is the connector's highest-complexity, least-tested
 * code, and the property under test here (a master + all its RECURRENCE-ID
 * overrides always share one CalDAV href/etag, per RFC 4791 §4.1) is why
 * incremental sync can safely fetch only changed hrefs.
 */

function privateMethod<T>(name: string): T {
  return (Apple.prototype as unknown as Record<string, T>)[name];
}

const processCalDAVEvents = privateMethod<
  (
    events: CalDAVEvent[],
    calendarHref: string,
    initialSync: boolean
  ) => Promise<void>
>("processCalDAVEvents");
const prepareEvent = privateMethod<
  (
    icsEvent: ICSEvent,
    calendarHref: string,
    initialSync: boolean,
    eventHref?: string
  ) => Promise<NewLinkWithNotes | null>
>("prepareEvent");
const prepareEventInstance = privateMethod<
  (
    icsEvent: ICSEvent,
    calendarHref: string,
    initialSync: boolean
  ) => Promise<NewLinkWithNotes | null>
>("prepareEventInstance");
const finishSync = privateMethod<
  (
    calendarHref: string,
    initialSync: boolean,
    phase?: "quick" | "full"
  ) => Promise<void>
>("finishSync");
const calDavHref = privateMethod<(channelId: string) => string>("calDavHref");
const schedulePoll = privateMethod<(calendarHref: string) => Promise<void>>(
  "schedulePoll"
);

const calendarHref = "calendar:/1234/calendars/home/";

/**
 * Duplicates `hashContent` from `apple.ts` (not exported) so the
 * description-note key assertion below doesn't need production changes.
 */
async function sha256Hex8(content: string): Promise<string> {
  const data = new TextEncoder().encode(content);
  const buf = await crypto.subtle.digest("SHA-256", data);
  const bytes = new Uint8Array(buf);
  let hex = "";
  for (let i = 0; i < 8; i++) {
    hex += bytes[i].toString(16).padStart(2, "0");
  }
  return hex;
}

/**
 * Wraps one or more VEVENT blocks in a realistic VCALENDAR envelope,
 * including a VTIMEZONE block with its own RRULE lines for DST transitions
 * (real Apple/iCloud payloads carry these). `parseICSEvents` only extracts
 * BEGIN:VEVENT/END:VEVENT blocks, so the VTIMEZONE's own RRULEs never leak
 * into a parsed ICSEvent's `rrule` — but a naive test that counted `RRULE`
 * occurrences via regex over the raw ICS text would be fooled by them.
 * Assertions below are always against parsed/structured output, never
 * against raw ICS text, for exactly this reason.
 */
function icsCalendar(veventsText: string): string {
  return [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Apple Inc.//iCloud Calendar 2.0//EN",
    "CALSCALE:GREGORIAN",
    "BEGIN:VTIMEZONE",
    "TZID:America/New_York",
    "BEGIN:DAYLIGHT",
    "TZOFFSETFROM:-0500",
    "TZOFFSETTO:-0400",
    "TZNAME:EDT",
    "DTSTART:20070311T020000",
    "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",
    "END:DAYLIGHT",
    "BEGIN:STANDARD",
    "TZOFFSETFROM:-0400",
    "TZOFFSETTO:-0500",
    "TZNAME:EST",
    "DTSTART:20071104T020000",
    "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU",
    "END:STANDARD",
    "END:VTIMEZONE",
    veventsText,
    "END:VCALENDAR",
  ].join("\r\n");
}

/**
 * Shared fake `self` for every describe block below. Exposes:
 *  - a plain-Map-backed `get`/`set`/`clear` (mirrors `this.set/get/clear`)
 *  - `tools.store.list`/`releaseLock` backed by the same Map (prefix scan)
 *  - `tools.integrations.saveLinks`/`channelSyncCompleted` as spies
 *  - `getCalDAV()` replaced with a stub client (no real network call)
 *  - the real (private) `prepareEvent`/`prepareEventInstance`/
 *    `processCalDAVEvents`/`finishSync`/`calDavHref`/`schedulePoll` copied
 *    from `Apple.prototype`, so `this.xxx(...)` dispatch inside the real
 *    implementations resolves correctly against this fake — same rationale
 *    as `privateMethod` usage in `apple.test.ts`.
 *  - `sync_enabled_<calendarHref>` seeded `true` so `schedulePoll` (reached
 *    via `finishSync`) doesn't bail out.
 */
function makeSelf(opts: { initialStore?: Record<string, unknown> } = {}) {
  const store = new Map<string, unknown>(
    Object.entries({
      [`sync_enabled_${calendarHref}`]: true,
      ...opts.initialStore,
    })
  );
  const list = vi.fn(async (prefix: string) =>
    Array.from(store.keys()).filter((k) => k.startsWith(prefix))
  );
  const releaseLock = vi.fn(async () => {});
  const saveLinksCalls: NewLinkWithNotes[][] = [];
  const saveLinks = vi.fn(async (links: NewLinkWithNotes[]) => {
    saveLinksCalls.push(links);
  });
  const channelSyncCompleted = vi.fn(async () => {});
  const getCalendarCtag = vi.fn(async () => null as string | null);
  const getSyncToken = vi.fn(async () => null as string | null);

  const self = {
    prepareEvent,
    prepareEventInstance,
    processCalDAVEvents,
    finishSync,
    calDavHref,
    schedulePoll,
    getCalDAV: () => ({ getCalendarCtag, getSyncToken }),
    get: async <T>(key: string) => (store.has(key) ? (store.get(key) as T) : null),
    set: async (key: string, value: unknown) => {
      store.set(key, value);
    },
    clear: async (key: string) => {
      store.delete(key);
    },
    callback: vi.fn(async () => ({})),
    scheduleRecurring: vi.fn(async () => {}),
    tools: {
      store: { list, releaseLock },
      integrations: { saveLinks, channelSyncCompleted },
    },
  } as unknown as Apple;

  return { self, store, saveLinksCalls, getCalendarCtag, getSyncToken };
}

describe("Apple.processCalDAVEvents — master + RECURRENCE-ID overrides share one href (RFC 4791 §4.1)", () => {
  // `parseICSDateTime`'s TZID branch (ics-parser.ts) internally does
  // `new Date("<local time, no Z suffix>")`, which Cloudflare Workers
  // (production) parses as UTC (isolates have no OS timezone) but Node
  // parses in the host OS's timezone. Left unpinned, this test's exact-UTC
  // assertions below are only correct on a UTC test machine — on the
  // machine this suite was authored on (America/Toronto) they were off by
  // several hours. Pin TZ=UTC for just this describe block so the
  // assertions reflect actual CF Workers production behavior regardless of
  // which timezone the test runner's host happens to be in. See the task
  // report for why this is flagged as a real (if currently latent) fragility
  // in ics-parser.ts, not just a test-authoring inconvenience.
  const originalTz = process.env.TZ;
  beforeAll(() => {
    process.env.TZ = "UTC";
  });
  afterAll(() => {
    process.env.TZ = originalTz;
  });

  // All-2099 dates so cancellationIsForPastEventFn (called with no `now`
  // override, i.e. the real current time) never treats the cancelled
  // override here as "already past" — same convention as the far-future
  // fixture already used in apple.test.ts's cancellation-note describe block.
  const masterVEvent = [
    "BEGIN:VEVENT",
    "UID:series-1@icloud.com",
    "DTSTAMP:20990101T120000Z",
    "DTSTART;TZID=America/New_York:20990106T090000",
    "DTEND;TZID=America/New_York:20990106T093000",
    "SUMMARY:Weekly Standup",
    "ORGANIZER;CN=Pat Organizer:mailto:organizer@example.com",
    "ATTENDEE;CN=Ada Attendee;PARTSTAT=ACCEPTED:mailto:ada@example.com",
    "RRULE:FREQ=WEEKLY;BYDAY=TU",
    "CREATED:20990101T090000Z",
    "LAST-MODIFIED:20990101T090000Z",
    "SEQUENCE:0",
    "END:VEVENT",
  ].join("\r\n");

  const movedOverrideVEvent = [
    "BEGIN:VEVENT",
    "UID:series-1@icloud.com",
    "DTSTAMP:20990108T120000Z",
    "RECURRENCE-ID;TZID=America/New_York:20990113T090000",
    "DTSTART;TZID=America/New_York:20990113T100000",
    "DTEND;TZID=America/New_York:20990113T103000",
    "SUMMARY:Weekly Standup (moved)",
    "ORGANIZER;CN=Pat Organizer:mailto:organizer@example.com",
    "ATTENDEE;CN=Ada Attendee;PARTSTAT=ACCEPTED:mailto:ada@example.com",
    "SEQUENCE:1",
    "END:VEVENT",
  ].join("\r\n");

  const cancelledOverrideVEvent = [
    "BEGIN:VEVENT",
    "UID:series-1@icloud.com",
    "DTSTAMP:20990108T120000Z",
    "RECURRENCE-ID;TZID=America/New_York:20990120T090000",
    "DTSTART;TZID=America/New_York:20990120T090000",
    "DTEND;TZID=America/New_York:20990120T093000",
    "SUMMARY:Weekly Standup",
    "STATUS:CANCELLED",
    "SEQUENCE:1",
    "END:VEVENT",
  ].join("\r\n");

  const masterPlusOverridesIcs = icsCalendar(
    [masterVEvent, movedOverrideVEvent, cancelledOverrideVEvent].join("\r\n")
  );

  it("coalesces a master (with RRULE) and its RECURRENCE-ID overrides into exactly ONE link — the master's title survives", async () => {
    const { self, saveLinksCalls } = makeSelf();
    const events: CalDAVEvent[] = [
      { href: "/cal/series-1.ics", etag: "etag-1", icsData: masterPlusOverridesIcs },
    ];

    await processCalDAVEvents.call(self, events, calendarHref, false);

    // THE core invariant: one href containing a master + N overrides
    // produces exactly one saveLinks call with exactly one link — never
    // N+1 separate links.
    expect(saveLinksCalls).toHaveLength(1);
    expect(saveLinksCalls[0]).toHaveLength(1);

    const link = saveLinksCalls[0][0];
    expect(link.source).toBe("apple-calendar:series-1@icloud.com");
    expect(link.sources).toEqual([
      "apple-calendar:series-1@icloud.com",
      "icaluid:series-1@icloud.com",
    ]);

    // The master's title survives; an override's own SUMMARY never
    // clobbers it (movedOverrideVEvent's SUMMARY is deliberately different).
    expect(link.title).toBe("Weekly Standup");
    expect(link.title).not.toBe("Weekly Standup (moved)");

    expect(link.schedules).toHaveLength(1);
    expect(link.schedules?.[0]).toMatchObject({
      start: new Date("2099-01-06T14:00:00.000Z"),
      end: new Date("2099-01-06T14:30:00.000Z"),
      recurrenceRule: "FREQ=WEEKLY;BYDAY=TU",
    });
    expect(link.meta).toMatchObject({
      uid: "series-1@icloud.com",
      syncProvider: "apple",
      syncableId: calendarHref,
    });

    // Both overrides land as occurrences on the SAME link, not as separate
    // links.
    expect(link.scheduleOccurrences).toHaveLength(2);

    const moved = link.scheduleOccurrences?.find(
      (o) =>
        (o.occurrence as Date).getTime() ===
        new Date("2099-01-13T14:00:00.000Z").getTime()
    );
    expect(moved).toBeDefined();
    expect(moved?.start).toEqual(new Date("2099-01-13T15:00:00.000Z"));
    expect(moved?.end).toEqual(new Date("2099-01-13T15:30:00.000Z"));
    expect(moved?.cancelled).toBeUndefined();

    const cancelled = link.scheduleOccurrences?.find(
      (o) => o.cancelled === true
    );
    expect(cancelled).toBeDefined();
    expect(cancelled?.occurrence).toEqual(new Date("2099-01-20T14:00:00.000Z"));
  });
});

describe("Apple.prepareEventInstance — initial vs incremental split", () => {
  const masterUid = "series-2@icloud.com";
  const masterSource = `apple-calendar:${masterUid}`;

  function overrideEvent(overrides: Partial<ICSEvent> = {}): ICSEvent {
    return {
      uid: masterUid,
      summary: "Weekly Standup (moved)", // deliberately not the master's title
      description: null,
      dtstart: { value: "20990113T100000Z", params: {} },
      dtend: { value: "20990113T103000Z", params: {} },
      duration: null,
      rrule: null,
      exdates: [],
      rdates: [],
      recurrenceId: { value: "20990113T090000Z", params: {} },
      status: null,
      location: null,
      organizer: null,
      attendees: [
        { email: "ada@example.com", name: "Ada Attendee", partstat: "ACCEPTED", role: null },
      ],
      sequence: 1,
      created: null,
      lastModified: null,
      url: null,
      ...overrides,
    };
  }

  it("initial sync: buffers the override under pending_occ: and returns null (never saved standalone)", async () => {
    const { self, store } = makeSelf();
    const icsEvent = overrideEvent();

    const result = await prepareEventInstance.call(self, icsEvent, calendarHref, true);

    expect(result).toBeNull();
    const key = `pending_occ:${calendarHref}:${masterSource}:2099-01-13T09:00:00.000Z`;
    expect(store.get(key)).toEqual({
      occurrence: new Date("2099-01-13T09:00:00.000Z"),
      start: new Date("2099-01-13T10:00:00.000Z"),
      contacts: [
        {
          contact: { email: "ada@example.com", name: "Ada Attendee" },
          status: "attend",
          role: "required",
        },
      ],
      unread: false,
      end: new Date("2099-01-13T10:30:00.000Z"),
    });
  });

  it("incremental sync: returns an occurrence-only link with title left undefined — never the override's own summary — so upsert can't clobber the master's stored title", async () => {
    const { self } = makeSelf();
    const icsEvent = overrideEvent();

    const result = await prepareEventInstance.call(self, icsEvent, calendarHref, false);

    expect(result).not.toBeNull();
    const link = result!;
    // The deliberate invariant under test: `title` is explicitly set to
    // `undefined` (present as a key, not omitted) — not the override's own
    // SUMMARY ("Weekly Standup (moved)").
    expect(Object.prototype.hasOwnProperty.call(link, "title")).toBe(true);
    expect(link.title).toBeUndefined();
    expect(link.title).not.toBe(icsEvent.summary);

    expect(link.source).toBe(masterSource);
    expect(link.sources).toEqual([
      "apple-calendar:series-2@icloud.com",
      "icaluid:series-2@icloud.com",
    ]);
    expect(link.notes).toEqual([]);
    expect(link.scheduleOccurrences).toHaveLength(1);
    expect(link.scheduleOccurrences?.[0]).toMatchObject({
      occurrence: new Date("2099-01-13T09:00:00.000Z"),
      start: new Date("2099-01-13T10:00:00.000Z"),
      end: new Date("2099-01-13T10:30:00.000Z"),
    });
    // No `unread` field on incremental — only initial sync sets it.
    expect(link.scheduleOccurrences?.[0]).not.toHaveProperty("unread");
  });

  it("cancelled override, incremental sync, future occurrence: kept and returned as a cancelled occurrence-only link", async () => {
    const { self } = makeSelf();
    const icsEvent = overrideEvent({
      status: "CANCELLED",
      recurrenceId: { value: "20990120T090000Z", params: {} },
      dtstart: { value: "20990120T090000Z", params: {} },
      dtend: { value: "20990120T093000Z", params: {} },
    });

    const result = await prepareEventInstance.call(self, icsEvent, calendarHref, false);

    expect(result).not.toBeNull();
    expect(result!.scheduleOccurrences).toEqual([
      {
        occurrence: new Date("2099-01-20T09:00:00.000Z"),
        start: new Date("2099-01-20T09:00:00.000Z"),
        end: new Date("2099-01-20T09:30:00.000Z"),
        cancelled: true,
      },
    ]);
  });

  it("cancelled override, incremental sync, past occurrence: dropped as noise (mirrors prepareEvent's past-cancellation drop)", async () => {
    const { self } = makeSelf();
    const icsEvent = overrideEvent({
      status: "CANCELLED",
      recurrenceId: { value: "20200101T090000Z", params: {} },
      dtstart: { value: "20200101T090000Z", params: {} },
      dtend: { value: "20200101T093000Z", params: {} },
    });

    const result = await prepareEventInstance.call(self, icsEvent, calendarHref, false);

    expect(result).toBeNull();
  });

  it("cancelled override, initial sync: buffered regardless of whether the occurrence is already past — this is DIFFERENT from prepareEvent's flat initial-sync skip for a cancelled MASTER (see report)", async () => {
    const { self, store } = makeSelf();
    const icsEvent = overrideEvent({
      status: "CANCELLED",
      recurrenceId: { value: "20200101T090000Z", params: {} },
      dtstart: { value: "20200101T090000Z", params: {} },
      dtend: { value: "20200101T093000Z", params: {} },
    });

    const result = await prepareEventInstance.call(self, icsEvent, calendarHref, true);

    expect(result).toBeNull(); // buffered, not dropped outright
    const key = `pending_occ:${calendarHref}:${masterSource}:2020-01-01T09:00:00.000Z`;
    // `unread: false` matches the non-cancelled occurrence branch: an initial
    // backfill lands already-read so importing a calendar can't notify about
    // occurrences cancelled long ago. This branch used to omit `unread`
    // entirely, which is the notification-spam failure the connector guide
    // calls out.
    expect(store.get(key)).toEqual({
      occurrence: new Date("2020-01-01T09:00:00.000Z"),
      start: new Date("2020-01-01T09:00:00.000Z"),
      end: new Date("2020-01-01T09:30:00.000Z"),
      cancelled: true,
      unread: false,
    });
  });

  it("cancelled override, incremental sync: omits unread so a real cancellation still surfaces", async () => {
    const { self, store } = makeSelf();
    const icsEvent = overrideEvent({
      status: "CANCELLED",
      recurrenceId: { value: "20990101T090000Z", params: {} },
      dtstart: { value: "20990101T090000Z", params: {} },
      dtend: { value: "20990101T093000Z", params: {} },
    });

    const result = await prepareEventInstance.call(self, icsEvent, calendarHref, false);

    expect(result).not.toBeNull();
    const occurrence = result?.scheduleOccurrences?.[0];
    expect(occurrence?.cancelled).toBe(true);
    expect(Object.prototype.hasOwnProperty.call(occurrence ?? {}, "unread")).toBe(false);
    // Incremental returns the occurrence directly; only initial sync buffers.
    const buffered = Array.from(store.keys()).filter((k) =>
      k.startsWith("pending_occ:")
    );
    expect(buffered).toEqual([]);
  });
});

describe("Apple.processCalDAVEvents / finishSync — pending_occ: cross-batch buffering + seen_master: orphan flush", () => {
  const masterUid = "series-3@icloud.com";
  const masterSource = `apple-calendar:${masterUid}`;

  const masterOnlyIcs = icsCalendar(
    [
      "BEGIN:VEVENT",
      `UID:${masterUid}`,
      "DTSTAMP:20990101T120000Z",
      "DTSTART:20990106T140000Z",
      "DTEND:20990106T143000Z",
      "SUMMARY:Weekly Standup",
      "RRULE:FREQ=WEEKLY;BYDAY=TU",
      "END:VEVENT",
    ].join("\r\n")
  );

  const overrideOnlyIcs = icsCalendar(
    [
      "BEGIN:VEVENT",
      `UID:${masterUid}`,
      "DTSTAMP:20990108T120000Z",
      "RECURRENCE-ID:20990113T140000Z",
      "DTSTART:20990113T150000Z",
      "DTEND:20990113T153000Z",
      "SUMMARY:Weekly Standup (moved)",
      "SEQUENCE:1",
      "END:VEVENT",
    ].join("\r\n")
  );

  const pendingKey = `pending_occ:${calendarHref}:${masterSource}:2099-01-13T14:00:00.000Z`;
  const seenMasterKey = `seen_master:${calendarHref}:${masterSource}`;

  it("override buffered in an earlier batch is drained the moment its master is processed in a later batch", async () => {
    const { self, store, saveLinksCalls } = makeSelf();

    // Batch A: the override's calendar-object resource is processed before
    // its master's (e.g. multiget response ordering).
    await processCalDAVEvents.call(
      self,
      [{ href: "/cal/override-1.ics", etag: "e1", icsData: overrideOnlyIcs }],
      calendarHref,
      true
    );
    expect(saveLinksCalls).toEqual([]); // buffered only — nothing saved yet
    expect(store.has(pendingKey)).toBe(true);

    // Batch B: the master arrives.
    await processCalDAVEvents.call(
      self,
      [{ href: "/cal/master-1.ics", etag: "e2", icsData: masterOnlyIcs }],
      calendarHref,
      true
    );

    expect(saveLinksCalls).toHaveLength(1); // exactly one saveLinks call, ever
    const link = saveLinksCalls[0][0];
    expect(link.source).toBe(masterSource);
    expect(link.title).toBe("Weekly Standup");
    expect(link.scheduleOccurrences).toHaveLength(1);
    expect(link.scheduleOccurrences?.[0]).toMatchObject({
      occurrence: new Date("2099-01-13T14:00:00.000Z"),
      start: new Date("2099-01-13T15:00:00.000Z"),
    });
    expect(store.has(pendingKey)).toBe(false); // drained
  });

  it("master processed first, override arrives in a LATER batch: undrained by the per-batch drain, then picked up by finishSync's orphan flush (seen_master matches)", async () => {
    const { self, store, saveLinksCalls } = makeSelf();

    // Batch A: master arrives and is saved standalone.
    await processCalDAVEvents.call(
      self,
      [{ href: "/cal/master-1.ics", etag: "e1", icsData: masterOnlyIcs }],
      calendarHref,
      true
    );
    expect(saveLinksCalls).toHaveLength(1);
    expect(saveLinksCalls[0][0].scheduleOccurrences).toBeUndefined();
    expect(store.get(seenMasterKey)).toBe(true);

    // Batch B: the override arrives alone. The per-batch drain in
    // processCalDAVEvents only looks at sources present in THIS batch's own
    // linksBySource — and a standalone buffered override produces none (it
    // returns null) — so it stays buffered, not merged into anything yet.
    await processCalDAVEvents.call(
      self,
      [{ href: "/cal/override-1.ics", etag: "e2", icsData: overrideOnlyIcs }],
      calendarHref,
      true
    );
    expect(saveLinksCalls).toHaveLength(1); // still just the one, from batch A
    expect(store.has(pendingKey)).toBe(true); // undrained leftover

    // finishSync's full-pass terminal flushes it because seen_master was
    // recorded when the master was processed in batch A.
    await finishSync.call(self, calendarHref, true, "full");

    expect(saveLinksCalls).toHaveLength(2);
    const flushLink = saveLinksCalls[1][0];
    expect(flushLink.source).toBe(masterSource);
    expect(flushLink.title).toBeUndefined(); // never clobbers the master's stored title
    expect(flushLink.scheduleOccurrences).toEqual([
      expect.objectContaining({
        occurrence: new Date("2099-01-13T14:00:00.000Z"),
      }),
    ]);
    expect(store.has(pendingKey)).toBe(false);
    expect(store.has(seenMasterKey)).toBe(false); // cleared for the next initial sync
  });

  it("orphan: a pending_occ leftover whose master never appeared in this initial sync is dropped silently, not flushed", async () => {
    const { self, store, saveLinksCalls } = makeSelf();

    // The override arrives; its master is never processed in this pass at
    // all (e.g. deleted upstream before this initial sync ever saw it).
    await processCalDAVEvents.call(
      self,
      [{ href: "/cal/override-1.ics", etag: "e1", icsData: overrideOnlyIcs }],
      calendarHref,
      true
    );
    expect(store.has(pendingKey)).toBe(true);
    expect(store.has(seenMasterKey)).toBe(false); // never seen this pass

    await finishSync.call(self, calendarHref, true, "full");

    // No seen_master marker → treated as a genuine orphan: dropped, never
    // flushed (flushing would create a useless empty Untitled thread).
    expect(saveLinksCalls).toEqual([]);
    expect(store.has(pendingKey)).toBe(false); // still cleared, just dropped
  });
});

describe("Apple.prepareEvent — basics", () => {
  it("builds title, schedule (start/end/rrule/exdates), attendees, and a content-hashed description note from a normal master event", async () => {
    const { self } = makeSelf();
    const description = "Discuss roadmap for Q1.\nBring your updates.";
    const icsEvent: ICSEvent = {
      uid: "evt-basic-1",
      summary: "Roadmap Review",
      description,
      dtstart: { value: "20990110T140000Z", params: {} },
      dtend: { value: "20990110T150000Z", params: {} },
      duration: null,
      rrule: "FREQ=WEEKLY;BYDAY=MO",
      exdates: [new Date("2099-01-17T14:00:00.000Z")],
      rdates: [],
      recurrenceId: null,
      status: "CONFIRMED",
      location: null,
      organizer: { email: "organizer@example.com", name: "Pat Organizer" },
      attendees: [
        { email: "ada@example.com", name: "Ada Attendee", partstat: "ACCEPTED", role: null },
        {
          email: "bo@example.com",
          name: "Bo Optional",
          partstat: "DECLINED",
          role: "OPT-PARTICIPANT",
        },
      ],
      sequence: 0,
      created: "20990101T090000Z",
      lastModified: "20990101T090000Z",
      url: null,
    };

    const link = await prepareEvent.call(
      self,
      icsEvent,
      calendarHref,
      false,
      "/cal/evt-basic-1.ics"
    );

    expect(link).not.toBeNull();
    expect(link!.title).toBe("Roadmap Review");
    expect(link!.source).toBe("apple-calendar:evt-basic-1");
    expect(link!.sources).toEqual([
      "apple-calendar:evt-basic-1",
      "icaluid:evt-basic-1",
    ]);
    expect(link!.created).toEqual(new Date("2099-01-01T09:00:00.000Z"));

    expect(link!.schedules?.[0]).toMatchObject({
      start: new Date("2099-01-10T14:00:00.000Z"),
      end: new Date("2099-01-10T15:00:00.000Z"),
      recurrenceRule: "FREQ=WEEKLY;BYDAY=MO",
      recurrenceExdates: [new Date("2099-01-17T14:00:00.000Z")],
    });
    expect(link!.schedules?.[0]?.contacts).toEqual([
      {
        contact: { email: "ada@example.com", name: "Ada Attendee" },
        status: "attend",
        role: "required",
      },
      {
        contact: { email: "bo@example.com", name: "Bo Optional" },
        status: "skip",
        role: "optional",
      },
    ]);
    expect(link!.author).toEqual({
      email: "organizer@example.com",
      name: "Pat Organizer",
    });

    expect(link!.preview).toBe(description.slice(0, 200));
    expect(link!.notes).toHaveLength(1);
    const expectedHash = await sha256Hex8(description);
    // `key` sits inside a `{id} | {key} | {}` union on NewNote, so a typed
    // `.key` property access doesn't type-check — assert structurally
    // instead.
    expect(link!.notes![0]).toMatchObject({
      key: `description-${expectedHash}`,
      content: description,
      contentType: "text",
      created: new Date("2099-01-01T09:00:00.000Z"),
    });
  });

  it("drops a cancelled event's incremental update when the event has already ended (surrounding behavior around cancellationIsForPastEventFn, not the helper itself — see cancellation-past.test.ts)", async () => {
    const { self } = makeSelf();
    const icsEvent: ICSEvent = {
      uid: "evt-past-cancel",
      summary: "Old Meeting",
      description: null,
      dtstart: { value: "20200101T140000Z", params: {} },
      dtend: { value: "20200101T150000Z", params: {} },
      duration: null,
      rrule: null,
      exdates: [],
      rdates: [],
      recurrenceId: null,
      status: "CANCELLED",
      location: null,
      organizer: null,
      attendees: [],
      sequence: 1,
      created: null,
      lastModified: "20200101T130000Z",
      url: null,
    };

    const link = await prepareEvent.call(
      self,
      icsEvent,
      calendarHref,
      false,
      "/cal/evt-past-cancel.ics"
    );

    expect(link).toBeNull();
  });
});

/**
 * `titled_uids_<calendarHref>` (FIX 1 support): a precise "this uid actually
 * got a titled link saved" signal, distinct from `event_uids_<calendarHref>`
 * (which records every href/uid CalDAV returned, REGARDLESS of whether
 * `prepareEvent` produced a link — see the `uidMap` write in
 * `processCalDAVEvents`, unconditional and BEFORE the `prepareEvent` call).
 * `knownEventUids()` (consumed by mail's bundling title decision) reads
 * `titled_uids_`, not `event_uids_` — using `event_uids_` directly would
 * report a cancelled-during-initial-sync event as "known" even though
 * `prepareEvent` returned null and no link/title was ever created for it,
 * silently reintroducing the exact "Untitled" bug FIX 1 exists to fix (the
 * review's own named "primary use case").
 */
describe("Apple.processCalDAVEvents — titled_uids_ tracking (FIX 1 support)", () => {
  const cancelledDuringInitialIcs = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "BEGIN:VEVENT",
    "UID:evt-cancelled-initial",
    "DTSTAMP:20990101T120000Z",
    "DTSTART:20990106T090000Z",
    "DTEND:20990106T093000Z",
    "SUMMARY:Cancelled Before Sync",
    "STATUS:CANCELLED",
    "SEQUENCE:1",
    "END:VEVENT",
    "END:VCALENDAR",
  ].join("\r\n");

  const normalIcs = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "BEGIN:VEVENT",
    "UID:evt-normal",
    "DTSTAMP:20990101T120000Z",
    "DTSTART:20990106T090000Z",
    "DTEND:20990106T093000Z",
    "SUMMARY:Team Sync",
    "STATUS:CONFIRMED",
    "SEQUENCE:0",
    "END:VEVENT",
    "END:VCALENDAR",
  ].join("\r\n");

  it("does NOT record a uid whose event was skipped (cancelled during initial sync — prepareEvent returns null)", async () => {
    const { self, store } = makeSelf();
    const event: CalDAVEvent = {
      href: "/cal/evt-cancelled-initial.ics",
      etag: "e1",
      icsData: cancelledDuringInitialIcs,
    };

    await processCalDAVEvents.call(self, [event], calendarHref, true); // initialSync = true

    // event_uids_ is unaffected by this fix — it still records every seen
    // href/uid, regardless of whether a link was produced (existing
    // behavior, needed for deletion archival by href — see FIX 3).
    expect(store.get(`event_uids_${calendarHref}`)).toEqual({
      "/cal/evt-cancelled-initial.ics": "evt-cancelled-initial",
    });
    // But titled_uids_ must be empty/absent — no titled link was ever
    // created for this uid.
    expect(store.get(`titled_uids_${calendarHref}`)).toBeUndefined();
  });

  it("DOES record a uid for a normal (non-cancelled) event that produces a titled link", async () => {
    const { self, store } = makeSelf();
    const event: CalDAVEvent = {
      href: "/cal/evt-normal.ics",
      etag: "e1",
      icsData: normalIcs,
    };

    await processCalDAVEvents.call(self, [event], calendarHref, true);

    expect(store.get(`titled_uids_${calendarHref}`)).toEqual({ "evt-normal": true });
  });

  it("DOES record a uid for a cancelled event on INCREMENTAL sync — it still produces a titled cancellation link", async () => {
    const { self, store } = makeSelf();
    const event: CalDAVEvent = {
      href: "/cal/evt-cancelled-incremental.ics",
      etag: "e1",
      icsData: cancelledDuringInitialIcs.replace("evt-cancelled-initial", "evt-cancelled-incremental"),
    };

    await processCalDAVEvents.call(self, [event], calendarHref, false); // initialSync = false

    expect(store.get(`titled_uids_${calendarHref}`)).toEqual({
      "evt-cancelled-incremental": true,
    });
  });
});
