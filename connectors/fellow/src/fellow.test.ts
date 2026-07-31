import { describe, expect, it, vi } from "vitest";
import type { Link } from "@plotday/twister";
import { Fellow } from "./fellow";
import type { FellowActionItem, FellowNote } from "./fellow-api";

function makeStore(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(Object.entries(initial));
  return {
    map,
    get: vi.fn(async (key: string) => (map.has(key) ? map.get(key) : null)),
    set: vi.fn(async (key: string, value: unknown) => void map.set(key, value)),
    clear: vi.fn(async (key: string) => void map.delete(key)),
    list: vi.fn(async (prefix: string) => [...map.keys()].filter((k) => k.startsWith(prefix))),
  };
}

function makeFellow(
  opts: {
    store?: ReturnType<typeof makeStore>;
    integrations?: Record<string, unknown>;
    options?: Record<string, unknown>;
  } = {}
): Fellow {
  const tools = {
    store: opts.store ?? makeStore(),
    integrations: {
      get: vi.fn().mockResolvedValue({ token: "tok" }),
      saveLink: vi.fn().mockResolvedValue("thread-1"),
      channelSyncCompleted: vi.fn().mockResolvedValue(undefined),
      ...opts.integrations,
    },
    options: { apiKey: "key", subdomain: "acme", ...opts.options },
  };
  return new Fellow("twist-1" as never, { getTools: () => tools } as never);
}

const channelId = "meeting-notes";

function note(id: string): FellowNote {
  return {
    id,
    title: `Note ${id}`,
    event_guid: null,
    event_start: null,
    event_end: null,
    event_is_all_day: false,
    recording_ids: [],
    content_markdown: "body",
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  };
}

function taskLinkFrom(overrides: Partial<Link> = {}): Link {
  return {
    threadId: "thread-1",
    source: "fellow:acme:action-item:ai1",
    created: new Date("2026-07-28T00:00:00Z"),
    author: null,
    title: "Send the recap",
    preview: null,
    assignee: null,
    type: "task",
    status: "done",
    actions: null,
    meta: { syncProvider: "fellow", channelId, actionItemId: "ai1" },
    sourceUrl: null,
    channelId,
    relatedSource: null,
    sources: ["fellow:acme:action-item:ai1"],
    ...overrides,
  } as unknown as Link;
}

function actionItem(overrides: Partial<FellowActionItem> = {}): FellowActionItem {
  return {
    id: "ai1",
    text: "Organize your action items into groups",
    status: "Incomplete",
    due_date: "2026-07-28",
    note_id: "n1",
    assignees: [{ id: "u1", full_name: "Tobin Braun", email: "tobin@acme.com" }],
    completion_type: null,
    ai_detected: false,
    ...overrides,
  };
}

describe("getChannels", () => {
  it("throws an actionable error instead of hitting the network when subdomain is blank", async () => {
    const fellow = makeFellow({ options: { subdomain: "" } });
    await expect(fellow.getChannels(null, null)).rejects.toThrow(/subdomain/i);
  });

  it("throws an actionable error instead of hitting the network when apiKey is blank", async () => {
    const fellow = makeFellow({ options: { apiKey: "" } });
    await expect(fellow.getChannels(null, null)).rejects.toThrow(/API key/i);
  });
});

/**
 * The platform re-stamps `initial_sync_started_at` (clearing any prior
 * `initial_sync_completed_at`) on EVERY channel enable, so the "Syncing…"
 * indicator turns back on each time. Any path through onChannelEnabled /
 * syncBatch that returns without reaching `channelSyncCompleted` therefore
 * leaves the connection spinning until the stuck-sync watchdog gives up and
 * mislabels a healthy connection "Reconnect".
 */
describe("initial sync completion is signalled on every exit path", () => {
  it("signals completion when the history range was already covered (early return)", async () => {
    const store = makeStore({
      [`sync_history_min_${channelId}`]: "2026-01-01T00:00:00.000Z",
    });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const fellow = makeFellow({ store, integrations: { channelSyncCompleted } });
    const startBatchSync = vi.fn().mockResolvedValue(undefined);
    (fellow as unknown as { startBatchSync: unknown }).startBatchSync = startBatchSync;

    await fellow.onChannelEnabled({ id: channelId, title: "Meeting Notes" } as never, {
      // Narrower than the stored min ⇒ already covered ⇒ early return.
      syncHistoryMin: new Date("2026-06-01T00:00:00Z"),
    } as never);

    expect(startBatchSync).not.toHaveBeenCalled();
    expect(channelSyncCompleted).toHaveBeenCalledWith(channelId);
  });

  it("does not persist the history marker until the backfill actually finishes", async () => {
    const store = makeStore();
    const fellow = makeFellow({ store });
    (fellow as unknown as { startBatchSync: unknown }).startBatchSync = vi
      .fn()
      .mockResolvedValue(undefined);
    (fellow as unknown as { callback: unknown }).callback = vi.fn().mockResolvedValue("cb");
    (fellow as unknown as { runTask: unknown }).runTask = vi.fn().mockResolvedValue(undefined);

    await fellow.onChannelEnabled({ id: channelId, title: "Meeting Notes" } as never, {
      syncHistoryMin: new Date("2026-01-01T00:00:00Z"),
    } as never);

    // Writing it here would arm the early return above for a sync that then
    // died mid-chain, permanently short-circuiting every later re-enable.
    expect(store.map.has(`sync_history_min_${channelId}`)).toBe(false);
  });

  it("persists the history marker once the last page is reached", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: {
        cursor: null,
        batchNumber: 2,
        notesProcessed: 5,
        initialSync: true,
        syncHistoryMin: "2026-01-01T00:00:00.000Z",
      },
    });
    const fellow = makeFellow({ store });
    (fellow as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({
      listNotes: vi.fn().mockResolvedValue({ data: [], nextCursor: null }),
      listActionItems: vi.fn().mockResolvedValue({ data: [] }),
    });

    await (
      fellow as unknown as { syncBatch: (id: string, initial?: boolean) => Promise<void> }
    ).syncBatch(channelId, true);

    expect(store.map.get(`sync_history_min_${channelId}`)).toBe(
      "2026-01-01T00:00:00.000Z"
    );
  });

  it("signals completion when the batch task is redelivered after the state was cleared", async () => {
    const store = makeStore(); // no sync_state_ ⇒ chain already finished
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const fellow = makeFellow({ store, integrations: { channelSyncCompleted } });

    await (
      fellow as unknown as { syncBatch: (id: string, initial?: boolean) => Promise<void> }
    ).syncBatch(channelId, true);

    expect(channelSyncCompleted).toHaveBeenCalledWith(channelId);
  });

  it("clears the history marker on disable so re-enabling re-syncs the archived links", async () => {
    const store = makeStore({
      [`sync_history_min_${channelId}`]: "2026-01-01T00:00:00.000Z",
      [`sync_enabled_${channelId}`]: true,
    });
    const archiveLinks = vi.fn().mockResolvedValue(undefined);
    const fellow = makeFellow({ store, integrations: { archiveLinks } });

    await fellow.onChannelDisabled({ id: channelId, title: "Meeting Notes" } as never);

    expect(archiveLinks).toHaveBeenCalled();
    // Leaving it set would make the next enable take the early return and come
    // back with no notes at all — the links were just archived.
    expect(store.map.has(`sync_history_min_${channelId}`)).toBe(false);
  });
});

describe("syncBatch", () => {
  it("carries syncHistoryMin into the next batch so pagination keeps its filter", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: {
        cursor: null,
        batchNumber: 1,
        notesProcessed: 0,
        initialSync: true,
        syncHistoryMin: "2026-01-01T00:00:00.000Z",
      },
    });
    const fellow = makeFellow({ store });
    const listNotes = vi
      .fn()
      .mockResolvedValue({ data: [note("n1")], nextCursor: "cursor2" });
    (fellow as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({
      listNotes,
      listActionItems: vi.fn().mockResolvedValue({ data: [] }),
    });
    (fellow as unknown as { callback: unknown }).callback = vi.fn().mockResolvedValue("cb");
    (fellow as unknown as { tools: { tasks: { runTask: unknown } } }).tools.tasks = {
      runTask: vi.fn().mockResolvedValue(undefined),
    };

    await (
      fellow as unknown as { syncBatch: (id: string, initial?: boolean) => Promise<void> }
    ).syncBatch(channelId, true);

    // Batch 1 filtered on the window...
    expect(listNotes).toHaveBeenCalledWith(
      expect.objectContaining({ updatedAtStart: "2026-01-01T00:00:00.000Z" })
    );
    // ...and batch 2 must too. Dropping it widened the result set the cursor
    // was issued against, so pagination walked a different list and re-saved
    // notes batch 1 had already written.
    const state = store.map.get(`sync_state_${channelId}`) as {
      syncHistoryMin?: string;
    };
    expect(state.syncHistoryMin).toBe("2026-01-01T00:00:00.000Z");
  });

  it("signals channelSyncCompleted when the last page is reached (initial sync)", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: {
        cursor: null,
        batchNumber: 1,
        notesProcessed: 0,
        initialSync: true,
      },
    });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const saveLink = vi.fn().mockResolvedValue("t1");
    const fellow = makeFellow({ store, integrations: { channelSyncCompleted, saveLink } });
    const listNotes = vi.fn().mockResolvedValue({ data: [note("n1")], nextCursor: null });
    const listActionItems = vi.fn().mockResolvedValue({ data: [] });
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, listActionItems });

    await (
      fellow as unknown as { syncBatch: (id: string, initial?: boolean) => Promise<void> }
    ).syncBatch(channelId, true);

    expect(saveLink).toHaveBeenCalledTimes(1);
    expect(channelSyncCompleted).toHaveBeenCalledWith(channelId);
    // sync state is cleared once the chain has nothing left to schedule
    expect(store.map.has(`sync_state_${channelId}`)).toBe(false);
  });

  it("does not signal channelSyncCompleted while more pages remain", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: {
        cursor: null,
        batchNumber: 1,
        notesProcessed: 0,
        initialSync: true,
      },
    });
    const channelSyncCompleted = vi.fn();
    const fellow = makeFellow({ store, integrations: { channelSyncCompleted } });
    const listNotes = vi
      .fn()
      .mockResolvedValue({ data: [note("n1")], nextCursor: "cursor2" });
    const listActionItems = vi.fn().mockResolvedValue({ data: [] });
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, listActionItems });
    (fellow as unknown as { callback: unknown }).callback = vi.fn().mockResolvedValue("cb");
    // syncBatch schedules the next batch via this.tools.tasks.runTask
    (fellow as unknown as { tools: { tasks: { runTask: unknown } } }).tools.tasks = {
      runTask: vi.fn().mockResolvedValue(undefined),
    };

    await (
      fellow as unknown as { syncBatch: (id: string, initial?: boolean) => Promise<void> }
    ).syncBatch(channelId, true);

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    const state = store.map.get(`sync_state_${channelId}`) as { cursor: string };
    expect(state.cursor).toBe("cursor2");
  });

  it("does not signal channelSyncCompleted when an incremental (non-initial) sync completes", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: {
        cursor: null,
        batchNumber: 1,
        notesProcessed: 0,
        initialSync: false,
      },
    });
    const channelSyncCompleted = vi.fn();
    const saveLink = vi.fn().mockResolvedValue("t1");
    const fellow = makeFellow({ store, integrations: { channelSyncCompleted, saveLink } });
    const listNotes = vi.fn().mockResolvedValue({ data: [note("n1")], nextCursor: null });
    const listActionItems = vi.fn().mockResolvedValue({ data: [] });
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, listActionItems });

    await (
      fellow as unknown as { syncBatch: (id: string, initial?: boolean) => Promise<void> }
    ).syncBatch(channelId, false);

    expect(channelSyncCompleted).not.toHaveBeenCalled();
  });

  it("omits the notes entry when content_markdown is still Fellow's blank agenda template", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: {
        cursor: null,
        batchNumber: 1,
        notesProcessed: 0,
        initialSync: true,
      },
    });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const fellow = makeFellow({ store, integrations: { saveLink } });
    const blankNote = {
      ...note("n1"),
      content_markdown:
        "## Talking Points\n\n_(The things to talk about)_\n\n" +
        "## Action Items\n\n_(What came out of this meeting? What are your next steps?)_\n\n" +
        "## Notepad\n\n_(Anything else to write down?)_",
    };
    const listNotes = vi.fn().mockResolvedValue({ data: [blankNote], nextCursor: null });
    const listActionItems = vi.fn().mockResolvedValue({ data: [] });
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, listActionItems });

    await (
      fellow as unknown as { syncBatch: (id: string, initial?: boolean) => Promise<void> }
    ).syncBatch(channelId, true);

    const link = saveLink.mock.calls[0][0];
    expect(link.notes).toEqual([]);
  });

  it("still syncs the notes entry when content_markdown has real content beyond the template", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: {
        cursor: null,
        batchNumber: 1,
        notesProcessed: 0,
        initialSync: true,
      },
    });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const fellow = makeFellow({ store, integrations: { saveLink } });
    const filledNote = {
      ...note("n1"),
      content_markdown:
        "## Talking Points\n\nDiscussed Q3 roadmap.\n\n" +
        "## Action Items\n\n_(What came out of this meeting? What are your next steps?)_\n\n" +
        "## Notepad\n\n_(Anything else to write down?)_",
    };
    const listNotes = vi.fn().mockResolvedValue({ data: [filledNote], nextCursor: null });
    const listActionItems = vi.fn().mockResolvedValue({ data: [] });
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, listActionItems });

    await (
      fellow as unknown as { syncBatch: (id: string, initial?: boolean) => Promise<void> }
    ).syncBatch(channelId, true);

    const link = saveLink.mock.calls[0][0];
    expect(link.notes).toEqual([
      expect.objectContaining({ key: "notes", content: filledNote.content_markdown }),
    ]);
  });
});

describe("action items", () => {
  it("syncs each action item as its own task link, assigned to the assignee", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: {
        cursor: null,
        batchNumber: 1,
        notesProcessed: 0,
        initialSync: true,
      },
    });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const fellow = makeFellow({ store, integrations: { saveLink } });
    const listNotes = vi.fn().mockResolvedValue({ data: [note("n1")], nextCursor: null });
    const listActionItems = vi.fn().mockResolvedValue({ data: [actionItem()] });
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, listActionItems });

    await (
      fellow as unknown as { syncBatch: (id: string, initial?: boolean) => Promise<void> }
    ).syncBatch(channelId, true);

    // One save for the meeting note link, one for the action item task link.
    expect(saveLink).toHaveBeenCalledTimes(2);
    const taskLink = saveLink.mock.calls[1][0];

    expect(taskLink.type).toBe("task");
    expect(taskLink.status).toBe("open");
    expect(taskLink.assignee).toEqual({
      email: "tobin@acme.com",
      name: "Tobin Braun",
      source: { accountId: "u1" },
    });
    expect(taskLink.meta.assigneeNames).toEqual(["Tobin Braun"]);

    // The note content is the raw item text (+ due date) — no leading
    // markdown checkbox and no assignee name baked into the text.
    expect(taskLink.notes[0].content).toBe(
      "Organize your action items into groups — due 2026-07-28",
    );
    expect(taskLink.notes[0].content).not.toMatch(/^\[.?\]/);
    expect(taskLink.notes[0].content).not.toContain("Tobin Braun");
  });

  it("maps Done and Archived statuses to done and archived task statuses", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: {
        cursor: null,
        batchNumber: 1,
        notesProcessed: 0,
        initialSync: false,
      },
    });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const fellow = makeFellow({ store, integrations: { saveLink } });
    const listNotes = vi.fn().mockResolvedValue({ data: [note("n1")], nextCursor: null });
    const listActionItems = vi.fn().mockResolvedValue({
      data: [
        actionItem({ id: "ai-done", status: "Done" }),
        actionItem({ id: "ai-archived", status: "Archived" }),
      ],
    });
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, listActionItems });

    await (
      fellow as unknown as { syncBatch: (id: string, initial?: boolean) => Promise<void> }
    ).syncBatch(channelId, false);

    expect(saveLink.mock.calls[1][0].status).toBe("done");
    expect(saveLink.mock.calls[2][0].status).toBe("archived");
  });
});

describe("onWebhook", () => {
  type Fn = (request: unknown, channelId: string) => Promise<void>;

  it("uses a stored cursor (with overlap) instead of a fixed lookback window, and saves the sync start time as the new cursor", async () => {
    const storedCursor = "2026-07-28T10:00:00.000Z";
    const store = makeStore({ [`sync_enabled_${channelId}`]: true, [`last_incremental_sync_${channelId}`]: storedCursor });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const fellow = makeFellow({ store, integrations: { saveLink } });
    const listNotes = vi.fn().mockResolvedValue({ data: [note("n1")], nextCursor: null });
    const listActionItems = vi.fn().mockResolvedValue({ data: [] });
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, listActionItems });

    const before = Date.now();
    await (fellow as unknown as { onWebhook: Fn }).onWebhook({}, channelId);
    const after = Date.now();

    // Queried from (storedCursor - overlap), not a fixed "one hour ago" window.
    expect(listNotes).toHaveBeenCalledWith(
      expect.objectContaining({
        updatedAtStart: new Date(new Date(storedCursor).getTime() - 5 * 60 * 1000).toISOString(),
      }),
    );

    // Cursor is advanced to (approximately) when the sync started.
    const newCursor = store.map.get(`last_incremental_sync_${channelId}`) as string;
    expect(new Date(newCursor).getTime()).toBeGreaterThanOrEqual(before);
    expect(new Date(newCursor).getTime()).toBeLessThanOrEqual(after);
  });

  it("falls back to a one-hour lookback window when no cursor is stored yet", async () => {
    const store = makeStore({ [`sync_enabled_${channelId}`]: true });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const fellow = makeFellow({ store, integrations: { saveLink } });
    const listNotes = vi.fn().mockResolvedValue({ data: [], nextCursor: null });
    const listActionItems = vi.fn().mockResolvedValue({ data: [] });
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, listActionItems });

    const before = Date.now();
    await (fellow as unknown as { onWebhook: Fn }).onWebhook({}, channelId);

    const calledWith = listNotes.mock.calls[0][0] as { updatedAtStart: string };
    const windowMs = before - new Date(calledWith.updatedAtStart).getTime();
    // Roughly one hour (allow slack for test execution time).
    expect(windowMs).toBeGreaterThan(59 * 60 * 1000);
    expect(windowMs).toBeLessThan(61 * 60 * 1000);
  });

  it("paginates through every page of notes updated since the cursor", async () => {
    const store = makeStore({ [`sync_enabled_${channelId}`]: true });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const fellow = makeFellow({ store, integrations: { saveLink } });
    const listNotes = vi
      .fn()
      .mockResolvedValueOnce({ data: [note("n1")], nextCursor: "page2" })
      .mockResolvedValueOnce({ data: [note("n2")], nextCursor: null });
    const listActionItems = vi.fn().mockResolvedValue({ data: [] });
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, listActionItems });

    await (fellow as unknown as { onWebhook: Fn }).onWebhook({}, channelId);

    expect(listNotes).toHaveBeenCalledTimes(2);
    expect(listNotes.mock.calls[1][0]).toEqual(
      expect.objectContaining({ cursor: "page2" }),
    );
    expect(saveLink).toHaveBeenCalledTimes(2);
  });

  it("does nothing when the channel's sync is not enabled", async () => {
    const store = makeStore(); // no sync_enabled_ key
    const saveLink = vi.fn();
    const fellow = makeFellow({ store, integrations: { saveLink } });
    const listNotes = vi.fn();
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, listActionItems: vi.fn() });

    await (fellow as unknown as { onWebhook: Fn }).onWebhook({}, channelId);

    expect(listNotes).not.toHaveBeenCalled();
    expect(saveLink).not.toHaveBeenCalled();
  });

  describe("action_item.assigned", () => {
    it("syncs a standalone action item (no note_id) straight from the payload, without touching the notes API", async () => {
      const store = makeStore({ [`sync_enabled_${channelId}`]: true });
      const saveLink = vi.fn().mockResolvedValue("t1");
      const fellow = makeFellow({ store, integrations: { saveLink } });
      const listNotes = vi.fn();
      const listActionItems = vi.fn();
      (fellow as unknown as { getAPI: unknown }).getAPI = vi
        .fn()
        .mockReturnValue({ listNotes, listActionItems });

      const request = {
        body: {
          event_type: "action_item.assigned",
          id: "ai-standalone",
          text: "Follow up with vendor",
          assignees: [{ id: "u1", full_name: "Tobin Braun", email: "tobin@acme.com" }],
          completion_type: "any",
          status: "Incomplete",
          due_date: null,
          note_id: null,
          ai_generated: false,
          created_at: "2026-07-28T10:00:00.000Z",
          updated_at: "2026-07-28T10:00:00.000Z",
        },
      };

      await (fellow as unknown as { onWebhook: Fn }).onWebhook(request, channelId);

      expect(listNotes).not.toHaveBeenCalled();
      expect(listActionItems).not.toHaveBeenCalled();
      expect(saveLink).toHaveBeenCalledTimes(1);
      const taskLink = saveLink.mock.calls[0][0];
      expect(taskLink.type).toBe("task");
      expect(taskLink.status).toBe("open");
      expect(taskLink.source).toBe("fellow:acme:action-item:ai-standalone");
      expect(taskLink.sourceUrl).toBeUndefined();
      expect(taskLink.meta.noteId).toBeNull();
      expect(taskLink.created).toEqual(new Date("2026-07-28T10:00:00.000Z"));
      expect(taskLink.assignee).toEqual({
        email: "tobin@acme.com",
        name: "Tobin Braun",
        source: { accountId: "u1" },
      });
    });

    it("builds a sourceUrl from note_id when the action item is attached to a note, without re-fetching notes", async () => {
      const store = makeStore({ [`sync_enabled_${channelId}`]: true });
      const saveLink = vi.fn().mockResolvedValue("t1");
      const fellow = makeFellow({ store, integrations: { saveLink } });
      const listNotes = vi.fn();
      (fellow as unknown as { getAPI: unknown }).getAPI = vi
        .fn()
        .mockReturnValue({ listNotes, listActionItems: vi.fn() });

      const request = {
        body: {
          event_type: "action_item.assigned",
          id: "ai1",
          text: "Send the recap",
          assignees: [{ id: "u1", full_name: "Tobin Braun", email: "tobin@acme.com" }],
          completion_type: "any",
          status: "Incomplete",
          due_date: null,
          note_id: "n1",
          ai_generated: false,
          created_at: "2026-07-28T10:00:00.000Z",
          updated_at: "2026-07-28T10:00:00.000Z",
        },
      };

      await (fellow as unknown as { onWebhook: Fn }).onWebhook(request, channelId);

      expect(listNotes).not.toHaveBeenCalled();
      const taskLink = saveLink.mock.calls[0][0];
      expect(taskLink.sourceUrl).toBe("https://acme.fellow.app/notes/n1");
      expect(taskLink.meta.noteId).toBe("n1");
    });
  });

  describe("action_item.completed", () => {
    it("maps the singular assignee shape and marks the task done", async () => {
      const store = makeStore({ [`sync_enabled_${channelId}`]: true });
      const saveLink = vi.fn().mockResolvedValue("t1");
      const fellow = makeFellow({ store, integrations: { saveLink } });
      (fellow as unknown as { getAPI: unknown }).getAPI = vi
        .fn()
        .mockReturnValue({ listNotes: vi.fn(), listActionItems: vi.fn() });

      const request = {
        body: {
          event_type: "action_item.completed",
          id: "ai1",
          text: "Send the recap",
          assignee_id: "u1",
          assignee_name: "Tobin Braun",
          assignee_email: "tobin@acme.com",
          note_id: null,
          due_date: null,
          done: true,
          wont_do: false,
          ai_generated: false,
        },
      };

      await (fellow as unknown as { onWebhook: Fn }).onWebhook(request, channelId);

      const taskLink = saveLink.mock.calls[0][0];
      expect(taskLink.status).toBe("done");
      expect(taskLink.assignee.name).toBe("Tobin Braun");
    });

    it("maps wont_do to archived", async () => {
      const store = makeStore({ [`sync_enabled_${channelId}`]: true });
      const saveLink = vi.fn().mockResolvedValue("t1");
      const fellow = makeFellow({ store, integrations: { saveLink } });
      (fellow as unknown as { getAPI: unknown }).getAPI = vi
        .fn()
        .mockReturnValue({ listNotes: vi.fn(), listActionItems: vi.fn() });

      const request = {
        body: {
          event_type: "action_item.completed",
          id: "ai1",
          text: "Send the recap",
          assignee_id: null,
          assignee_name: null,
          assignee_email: null,
          note_id: null,
          due_date: null,
          done: false,
          wont_do: true,
          ai_generated: false,
        },
      };

      await (fellow as unknown as { onWebhook: Fn }).onWebhook(request, channelId);

      const taskLink = saveLink.mock.calls[0][0];
      expect(taskLink.status).toBe("archived");
      expect(taskLink.assignee).toBeNull();
    });
  });

  describe("ai_note.generated", () => {
    function aiNoteRequest(overrides: Record<string, unknown> = {}) {
      return {
        body: {
          event_type: "ai_note.generated",
          id: "n1",
          event_id: "event-guid-1",
          event_title: "Weekly Sync",
          event_start: "2026-07-28T10:00:00.000Z",
          recap_url: "https://acme.fellow.app/notes/n1/recap",
          ai_notes: "## Summary\n\nWe discussed the roadmap.",
          ...overrides,
        },
      };
    }

    it("applies the AI-generated notes straight from the payload, as their own note on the same link the agenda sync upserts", async () => {
      const store = makeStore({ [`sync_enabled_${channelId}`]: true });
      const saveLink = vi.fn().mockResolvedValue("t1");
      const fellow = makeFellow({ store, integrations: { saveLink } });
      const listNotes = vi.fn().mockResolvedValue({ data: [], nextCursor: null });
      (fellow as unknown as { getAPI: unknown }).getAPI = vi
        .fn()
        .mockReturnValue({ listNotes, listActionItems: vi.fn() });

      await (fellow as unknown as { onWebhook: Fn }).onWebhook(aiNoteRequest(), channelId);

      const aiNoteLink = saveLink.mock.calls[0][0];
      expect(aiNoteLink.source).toBe("fellow:acme:note:n1");
      expect(aiNoteLink.sources).toEqual(
        expect.arrayContaining([
          "fellow:acme:note:n1",
          "icaluid:event-guid-1",
          "google-calendar:event-guid-1",
          "google-event:event-guid-1",
        ]),
      );
      expect(aiNoteLink.notes).toEqual([
        expect.objectContaining({
          key: "ai-notes",
          content: "## Summary\n\nWe discussed the roadmap.",
          author: null,
        }),
      ]);
    });

    it("still falls through to the generic re-sync so the agenda/content_markdown note isn't missed", async () => {
      const store = makeStore({ [`sync_enabled_${channelId}`]: true });
      const saveLink = vi.fn().mockResolvedValue("t1");
      const fellow = makeFellow({ store, integrations: { saveLink } });
      const listNotes = vi.fn().mockResolvedValue({ data: [note("n1")], nextCursor: null });
      const listActionItems = vi.fn().mockResolvedValue({ data: [] });
      (fellow as unknown as { getAPI: unknown }).getAPI = vi
        .fn()
        .mockReturnValue({ listNotes, listActionItems });

      await (fellow as unknown as { onWebhook: Fn }).onWebhook(aiNoteRequest(), channelId);

      expect(listNotes).toHaveBeenCalled();
      // One save for the ai-notes-only payload update, one for the
      // content_markdown-driven re-sync of the same note.
      expect(saveLink).toHaveBeenCalledTimes(2);
    });

    it("skips the targeted save (but still re-syncs) when the payload has no ai_notes content", async () => {
      const store = makeStore({ [`sync_enabled_${channelId}`]: true });
      const saveLink = vi.fn().mockResolvedValue("t1");
      const fellow = makeFellow({ store, integrations: { saveLink } });
      const listNotes = vi.fn().mockResolvedValue({ data: [], nextCursor: null });
      (fellow as unknown as { getAPI: unknown }).getAPI = vi
        .fn()
        .mockReturnValue({ listNotes, listActionItems: vi.fn() });

      await (fellow as unknown as { onWebhook: Fn }).onWebhook(
        aiNoteRequest({ ai_notes: null }),
        channelId,
      );

      expect(saveLink).not.toHaveBeenCalled();
      expect(listNotes).toHaveBeenCalled();
    });
  });
});

describe("onLinkUpdated", () => {
  it("completes the action item in Fellow when marked done in Plot", async () => {
    const fellow = makeFellow();
    const completeActionItem = vi.fn().mockResolvedValue(undefined);
    const archiveActionItem = vi.fn().mockResolvedValue(undefined);
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ completeActionItem, archiveActionItem });

    await fellow.onLinkUpdated(taskLinkFrom({ status: "done" }));

    expect(completeActionItem).toHaveBeenCalledWith("ai1", true);
    expect(archiveActionItem).not.toHaveBeenCalled();
  });

  it("reopens the action item in Fellow when moved back to open in Plot", async () => {
    const fellow = makeFellow();
    const completeActionItem = vi.fn().mockResolvedValue(undefined);
    const archiveActionItem = vi.fn().mockResolvedValue(undefined);
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ completeActionItem, archiveActionItem });

    await fellow.onLinkUpdated(taskLinkFrom({ status: "open" }));

    expect(completeActionItem).toHaveBeenCalledWith("ai1", false);
    expect(archiveActionItem).not.toHaveBeenCalled();
  });

  it("archives the action item in Fellow when marked archived in Plot", async () => {
    const fellow = makeFellow();
    const completeActionItem = vi.fn().mockResolvedValue(undefined);
    const archiveActionItem = vi.fn().mockResolvedValue(undefined);
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ completeActionItem, archiveActionItem });

    await fellow.onLinkUpdated(taskLinkFrom({ status: "archived" }));

    expect(archiveActionItem).toHaveBeenCalledWith("ai1");
    expect(completeActionItem).not.toHaveBeenCalled();
  });

  it("ignores non-task links", async () => {
    const fellow = makeFellow();
    const completeActionItem = vi.fn().mockResolvedValue(undefined);
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ completeActionItem });

    await fellow.onLinkUpdated(taskLinkFrom({ type: "meeting" }));

    expect(completeActionItem).not.toHaveBeenCalled();
  });

  it("ignores task links without an actionItemId (e.g. legacy or malformed meta)", async () => {
    const fellow = makeFellow();
    const completeActionItem = vi.fn().mockResolvedValue(undefined);
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ completeActionItem });

    await fellow.onLinkUpdated(taskLinkFrom({ meta: { syncProvider: "fellow", channelId } }));

    expect(completeActionItem).not.toHaveBeenCalled();
  });

  it("does not throw when the Fellow API call fails (best-effort write-back)", async () => {
    const fellow = makeFellow();
    const completeActionItem = vi.fn().mockRejectedValue(new Error("Fellow API error 500"));
    (fellow as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ completeActionItem });

    await expect(fellow.onLinkUpdated(taskLinkFrom({ status: "done" }))).resolves.toBeUndefined();
  });
});
