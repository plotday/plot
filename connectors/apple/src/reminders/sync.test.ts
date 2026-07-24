import { beforeEach, describe, expect, it, vi } from "vitest";

import { AuthenticationError, InvalidSyncTokenError } from "../calendar/caldav";
import {
  type RemindersHost,
  type RemindersListState,
  fullSyncFn,
  onChannelDisabledFn,
  onChannelEnabledFn,
  pollFn,
  processSyncChunkFn,
} from "./sync";

function makeIcs(uid: string, opts: { relatedTo?: string; status?: string } = {}): string {
  return [
    "BEGIN:VCALENDAR",
    "BEGIN:VTODO",
    `UID:${uid}`,
    `SUMMARY:Task ${uid}`,
    ...(opts.status ? [`STATUS:${opts.status}`] : []),
    ...(opts.relatedTo ? [`RELATED-TO:${opts.relatedTo}`] : []),
    "END:VTODO",
    "END:VCALENDAR",
  ].join("\r\n");
}

function makeHost(overrides: Partial<ReturnType<typeof baseHostParts>> = {}) {
  const parts = { ...baseHostParts(), ...overrides };
  const store = new Map<string, unknown>();
  const host: RemindersHost = {
    id: "conn-1",
    caldav: parts.caldav,
    set: async (key, value) => void store.set(key, value),
    get: async (key) => store.get(key) as never,
    clear: async (key) => void store.delete(key),
    setMany: async (entries) => {
      for (const [k, v] of entries) store.set(k, v);
    },
    tools: { integrations: parts.integrations },
    scheduler: parts.scheduler,
  };
  return { host, store, ...parts };
}

function baseHostParts() {
  return {
    caldav: {
      fetchTodos: vi.fn().mockResolvedValue([]),
      getCalendarCtag: vi.fn().mockResolvedValue("ctag-1"),
      getSyncToken: vi.fn().mockResolvedValue("token-1"),
      getCollectionChanges: vi.fn(),
      fetchEventsByHref: vi.fn().mockResolvedValue([]),
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any,
    integrations: {
      saveLink: vi.fn().mockResolvedValue("thread-1"),
      channelSyncCompleted: vi.fn().mockResolvedValue(undefined),
      archiveLinks: vi.fn().mockResolvedValue(undefined),
    },
    scheduler: {
      schedulePoll: vi.fn().mockResolvedValue(undefined),
      cancelPoll: vi.fn().mockResolvedValue(undefined),
      queueFullSync: vi.fn().mockResolvedValue(undefined),
    },
  };
}

describe("onChannelEnabledFn / onChannelDisabledFn", () => {
  it("marks the list enabled", async () => {
    const { host, store } = makeHost();
    await onChannelEnabledFn(host, "/tasks/home/");
    expect(store.get("enabled:/tasks/home/")).toBe(true);
  });

  it("on recovery, clears prior state and cancels any scheduled poll before re-enabling", async () => {
    const { host, store, scheduler } = makeHost();
    store.set("list:/tasks/home/", { syncToken: "stale", ctag: "stale", hrefUid: {} });
    await onChannelEnabledFn(host, "/tasks/home/", { recovering: true });

    expect(store.has("list:/tasks/home/")).toBe(false);
    expect(scheduler.cancelPoll).toHaveBeenCalledWith("/tasks/home/");
    expect(store.get("enabled:/tasks/home/")).toBe(true);
  });

  it("disable cancels the poll, clears state, and archives the channel's reminder links", async () => {
    const { host, scheduler, integrations, store } = makeHost();
    store.set("enabled:/tasks/home/", true);
    store.set("list:/tasks/home/", { syncToken: "t", ctag: "c", hrefUid: {} });

    await onChannelDisabledFn(host, "/tasks/home/");

    expect(scheduler.cancelPoll).toHaveBeenCalledWith("/tasks/home/");
    expect(store.has("enabled:/tasks/home/")).toBe(false);
    expect(store.has("list:/tasks/home/")).toBe(false);
    expect(integrations.archiveLinks).toHaveBeenCalledWith({
      channelId: "/tasks/home/",
      type: "reminder",
    });
  });
});

describe("fullSyncFn / processSyncChunkFn", () => {
  it("saves every fetched todo and seeds the sync token/ctag", async () => {
    const { host, caldav, integrations, store } = makeHost({
      caldav: {
        ...baseHostParts().caldav,
        fetchTodos: vi.fn().mockResolvedValue([
          { href: "/tasks/home/a.ics", etag: "e1", icsData: makeIcs("a") },
          { href: "/tasks/home/b.ics", etag: "e2", icsData: makeIcs("b") },
        ]),
      },
    });

    const result = await fullSyncFn(host, "/tasks/home/", true);

    expect(result).toEqual({ done: true });
    expect(integrations.saveLink).toHaveBeenCalledTimes(2);
    expect(integrations.channelSyncCompleted).toHaveBeenCalledWith("/tasks/home/");
    const state = store.get("list:/tasks/home/") as RemindersListState;
    expect(state.syncToken).toBe("token-1");
    expect(state.ctag).toBe("ctag-1");
    expect(state.hrefUid).toEqual({ "/tasks/home/a.ics": "a", "/tasks/home/b.ics": "b" });
  });

  it("de-namespaces a 'reminders:<href>' listId to the raw href for the CalDAV call, but keeps the namespaced id as the saved link's channelId", async () => {
    const { host, caldav, integrations } = makeHost({
      caldav: {
        ...baseHostParts().caldav,
        fetchTodos: vi.fn().mockResolvedValue([
          { href: "/tasks/home/a.ics", etag: "e1", icsData: makeIcs("a") },
        ]),
      },
    });

    await fullSyncFn(host, "reminders:/289842362/tasks/home/", true);

    expect(caldav.fetchTodos).toHaveBeenCalledWith("/289842362/tasks/home/");
    const [savedLink] = integrations.saveLink.mock.calls[0];
    expect(savedLink.channelId).toBe("reminders:/289842362/tasks/home/");
  });

  it("does not call channelSyncCompleted on a non-initial (ctag-fallback) full rescan", async () => {
    const { host, integrations } = makeHost({
      caldav: {
        ...baseHostParts().caldav,
        fetchTodos: vi.fn().mockResolvedValue([
          { href: "/tasks/home/a.ics", etag: "e1", icsData: makeIcs("a") },
        ]),
      },
    });
    await fullSyncFn(host, "/tasks/home/", false);
    expect(integrations.channelSyncCompleted).not.toHaveBeenCalled();
  });

  it("archives (does not save) a CANCELLED todo", async () => {
    const { host, integrations } = makeHost({
      caldav: {
        ...baseHostParts().caldav,
        fetchTodos: vi.fn().mockResolvedValue([
          { href: "/tasks/home/a.ics", etag: "e1", icsData: makeIcs("a", { status: "CANCELLED" }) },
        ]),
      },
    });
    await fullSyncFn(host, "/tasks/home/", true);
    expect(integrations.saveLink).not.toHaveBeenCalled();
    expect(integrations.archiveLinks).toHaveBeenCalledWith({
      channelId: "/tasks/home/",
      type: "reminder",
      meta: { todoUid: "a" },
    });
  });

  it("nests a subtask under its parent when both are in the same chunk", async () => {
    const { host, integrations } = makeHost({
      caldav: {
        ...baseHostParts().caldav,
        fetchTodos: vi.fn().mockResolvedValue([
          { href: "/tasks/home/parent.ics", etag: "e1", icsData: makeIcs("parent") },
          {
            href: "/tasks/home/child.ics",
            etag: "e2",
            icsData: makeIcs("child", { relatedTo: "parent" }),
          },
        ]),
      },
    });
    await fullSyncFn(host, "/tasks/home/", true);

    // Only the parent gets its own link; the subtask rides along as a note.
    expect(integrations.saveLink).toHaveBeenCalledTimes(1);
    const [savedLink] = integrations.saveLink.mock.calls[0];
    expect(savedLink.notes.some((n: { key: string }) => n.key === "subtask-child")).toBe(true);
  });

  it("continues via processSyncChunkFn when more than one chunk remains, threading the remainder", async () => {
    const resources = Array.from({ length: 60 }, (_, i) => ({
      href: `/tasks/home/t${i}.ics`,
      etag: `e${i}`,
      icsData: makeIcs(`t${i}`),
    }));
    const { host, integrations, store } = makeHost({
      caldav: { ...baseHostParts().caldav, fetchTodos: vi.fn().mockResolvedValue(resources) },
    });

    const first = await fullSyncFn(host, "/tasks/home/", true);
    expect(first).toMatchObject({ next: { listId: "/tasks/home/", offset: 50 } });
    expect(integrations.saveLink).toHaveBeenCalledTimes(50);
    expect(integrations.channelSyncCompleted).not.toHaveBeenCalled();
    // The full pending list stays in the store between chunks — never as a
    // callback/task argument (see reminders/sync.ts's SyncBatchResult doc).
    expect(store.has("pending:/tasks/home/")).toBe(true);

    if (!("next" in first)) throw new Error("expected next");
    const second = await processSyncChunkFn(host, "/tasks/home/", first.next.offset, true);
    expect(second).toEqual({ done: true });
    expect(integrations.saveLink).toHaveBeenCalledTimes(60);
    expect(integrations.channelSyncCompleted).toHaveBeenCalledWith("/tasks/home/");
    // Fully drained: the pending list is cleared, not left orphaned.
    expect(store.has("pending:/tasks/home/")).toBe(false);
  });

  it("persists the real CalDAV resource href in meta.todoHref, not a UID-based reconstruction", async () => {
    const { host, integrations } = makeHost({
      caldav: {
        ...baseHostParts().caldav,
        fetchTodos: vi.fn().mockResolvedValue([
          { href: "/tasks/home/some-server-assigned-path.ics", etag: "e1", icsData: makeIcs("a") },
        ]),
      },
    });

    await fullSyncFn(host, "/tasks/home/", true);

    const [savedLink] = integrations.saveLink.mock.calls[0];
    expect(savedLink.meta.todoHref).toBe("/tasks/home/some-server-assigned-path.ics");
    // The naive `<uid>.ics` reconstruction would have produced "a.ics" — the
    // real href must win, not that guess.
    expect(savedLink.meta.todoHref).not.toBe("/tasks/home/a.ics");
  });
});

describe("pollFn", () => {
  let host: RemindersHost;
  let store: Map<string, unknown>;
  let caldav: ReturnType<typeof baseHostParts>["caldav"];
  let integrations: ReturnType<typeof baseHostParts>["integrations"];
  let scheduler: ReturnType<typeof baseHostParts>["scheduler"];

  beforeEach(() => {
    const built = makeHost();
    host = built.host;
    store = built.store;
    caldav = built.caldav;
    integrations = built.integrations;
    scheduler = built.scheduler;
    store.set("enabled:/tasks/home/", true);
    store.set("list:/tasks/home/", {
      syncToken: "token-1",
      ctag: "ctag-1",
      hrefUid: { "/tasks/home/a.ics": "a" },
    } satisfies RemindersListState);
  });

  it("cancels the poll and returns early when the channel is no longer enabled", async () => {
    store.delete("enabled:/tasks/home/");
    await pollFn(host, "/tasks/home/");
    expect(scheduler.cancelPoll).toHaveBeenCalledWith("/tasks/home/");
    expect(caldav.getCollectionChanges).not.toHaveBeenCalled();
  });

  it("applies a fast-path delta: saves changed, archives deleted, persists the new token", async () => {
    caldav.getCollectionChanges.mockResolvedValue({
      token: "token-2",
      changed: [{ href: "/tasks/home/b.ics", etag: "e2" }],
      deletedHrefs: ["/tasks/home/a.ics"],
    });
    caldav.fetchEventsByHref.mockResolvedValue([
      { href: "/tasks/home/b.ics", etag: "e2", icsData: makeIcs("b") },
    ]);

    await pollFn(host, "/tasks/home/");

    expect(integrations.archiveLinks).toHaveBeenCalledWith({
      channelId: "/tasks/home/",
      type: "reminder",
      meta: { todoUid: "a" },
    });
    expect(integrations.saveLink).toHaveBeenCalledTimes(1);
    const state = store.get("list:/tasks/home/") as RemindersListState;
    expect(state.syncToken).toBe("token-2");
    expect(state.hrefUid).toEqual({ "/tasks/home/b.ics": "b" });
    expect(scheduler.schedulePoll).toHaveBeenCalledWith("/tasks/home/");
  });

  it("archives a todo that turned CANCELLED in the delta instead of saving it", async () => {
    caldav.getCollectionChanges.mockResolvedValue({
      token: "token-2",
      changed: [{ href: "/tasks/home/a.ics", etag: "e2" }],
      deletedHrefs: [],
    });
    caldav.fetchEventsByHref.mockResolvedValue([
      { href: "/tasks/home/a.ics", etag: "e2", icsData: makeIcs("a", { status: "CANCELLED" }) },
    ]);

    await pollFn(host, "/tasks/home/");

    expect(integrations.saveLink).not.toHaveBeenCalled();
    expect(integrations.archiveLinks).toHaveBeenCalledWith({
      channelId: "/tasks/home/",
      type: "reminder",
      meta: { todoUid: "a" },
    });
  });

  it("on an invalid sync token, clears it and falls back to the ctag check", async () => {
    caldav.getCollectionChanges.mockRejectedValue(new InvalidSyncTokenError());
    caldav.getCalendarCtag.mockResolvedValue("ctag-1"); // unchanged

    await pollFn(host, "/tasks/home/");

    expect(caldav.fetchTodos).not.toHaveBeenCalled(); // ctag unchanged -> no rescan
    expect(scheduler.schedulePoll).toHaveBeenCalledWith("/tasks/home/");
  });

  it("skips the rescan when the ctag fallback finds nothing changed", async () => {
    store.set("list:/tasks/home/", { syncToken: null, ctag: "ctag-1", hrefUid: {} });
    caldav.getCalendarCtag.mockResolvedValue("ctag-1");

    await pollFn(host, "/tasks/home/");

    expect(caldav.fetchTodos).not.toHaveBeenCalled();
    expect(scheduler.schedulePoll).toHaveBeenCalledWith("/tasks/home/");
  });

  it("queues a chunked full rescan (does not fetch/save inline) when the ctag fallback finds a change", async () => {
    // pollFn must NEVER call fullSyncFn/fetchTodos/saveLink directly for a
    // rescan — a list bigger than one chunk would have its remainder silently
    // dropped (fullSyncFn seeds a FRESH sync token covering the whole list in
    // one REPORT, so any un-saved remainder is then permanently invisible to
    // every future incremental poll, which correctly reports "nothing new").
    // Rescans must route through host.scheduler.queueFullSync so they chunk
    // across executions via the SAME continuation chain the initial backfill
    // uses. This test would have passed against the original (buggy) inline
    // fullSyncFn call too if it only asserted "a rescan happened" — the
    // `not.toHaveBeenCalled()` assertions are what actually pin the fix.
    store.set("list:/tasks/home/", { syncToken: null, ctag: "ctag-1", hrefUid: {} });
    caldav.getCalendarCtag.mockResolvedValue("ctag-2");

    await pollFn(host, "/tasks/home/");

    expect(caldav.fetchTodos).not.toHaveBeenCalled();
    expect(integrations.saveLink).not.toHaveBeenCalled();
    expect(scheduler.queueFullSync).toHaveBeenCalledWith("/tasks/home/", false);
    // The queued task's own completion schedules the next poll, not pollFn itself.
    expect(scheduler.schedulePoll).not.toHaveBeenCalled();
  });

  it("swallows an authentication error and reschedules rather than throwing", async () => {
    caldav.getCollectionChanges.mockRejectedValue(new AuthenticationError());

    await expect(pollFn(host, "/tasks/home/")).resolves.toBeUndefined();
    expect(scheduler.schedulePoll).toHaveBeenCalledWith("/tasks/home/");
  });

  it("queues a chunked, INITIAL-flagged full sync (not inline) when no state exists yet", async () => {
    // Treated as initialSync:true (not false) — matches Calendar's
    // "recovering" semantics: a lost cursor means every item in the list is
    // about to be (re-)saved for the first time from this connector's
    // perspective, so it must suppress unread/archived defaults the same way
    // a fresh backfill does, or every item in the list would surface as a
    // notification-worthy change.
    store.delete("list:/tasks/home/");

    await pollFn(host, "/tasks/home/");

    expect(caldav.fetchTodos).not.toHaveBeenCalled();
    expect(scheduler.queueFullSync).toHaveBeenCalledWith("/tasks/home/", true);
    expect(scheduler.schedulePoll).not.toHaveBeenCalled();
  });
});
