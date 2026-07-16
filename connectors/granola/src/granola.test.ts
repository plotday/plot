import { describe, expect, it, vi } from "vitest";
import { Granola } from "./granola";
import { GranolaApiError, type GranolaNote } from "./granola-api";

function makeStore(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(Object.entries(initial));
  return {
    map,
    get: vi.fn(async (key: string) => (map.has(key) ? map.get(key) : null)),
    set: vi.fn(async (key: string, value: unknown) => void map.set(key, value)),
    clear: vi.fn(async (key: string) => void map.delete(key)),
    list: vi.fn(async (prefix: string) =>
      [...map.keys()].filter((k) => k.startsWith(prefix))
    ),
  };
}

function makeGranola(
  opts: {
    store?: ReturnType<typeof makeStore>;
    integrations?: Record<string, unknown>;
    options?: Record<string, unknown>;
    tasks?: Record<string, unknown>;
  } = {}
): { granola: Granola; tasks: { runTask: ReturnType<typeof vi.fn> } } {
  const tasks = { runTask: vi.fn().mockResolvedValue(undefined), ...opts.tasks };
  const tools = {
    store: opts.store ?? makeStore(),
    integrations: {
      saveNotes: vi.fn().mockResolvedValue(undefined),
      channelSyncCompleted: vi.fn().mockResolvedValue(undefined),
      markNeedsReauth: vi.fn().mockResolvedValue(undefined),
      ...opts.integrations,
    },
    options: { apiKey: "grn_test", ...opts.options },
    tasks,
  };
  return {
    granola: new Granola("twist-1" as never, { getTools: () => tools } as never),
    tasks: tasks as { runTask: ReturnType<typeof vi.fn> },
  };
}

const channelId = "meeting-notes";

function noteSummary(id: string) {
  return { id, object: "note" as const, title: `Note ${id}`, owner: { name: null, email: "a@b.com" }, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z" };
}

function fullNote(id: string): GranolaNote {
  return {
    ...noteSummary(id),
    web_url: `https://granola.ai/notes/${id}`,
    calendar_event: null,
    attendees: [],
    summary_text: "body",
    summary_markdown: "body",
  };
}

describe("syncBatch", () => {
  it("signals channelSyncCompleted when the last page is reached (initial sync)", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: { cursor: null, initialSync: true },
    });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const saveNotes = vi.fn().mockResolvedValue(undefined);
    const { granola } = makeGranola({
      store,
      integrations: { channelSyncCompleted, saveNotes },
    });
    const listNotes = vi
      .fn()
      .mockResolvedValue({ data: [noteSummary("n1")], cursor: null, hasMore: false });
    const getNote = vi.fn().mockResolvedValue(fullNote("n1"));
    (granola as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, getNote });

    await (
      granola as unknown as {
        syncBatch: (id: string, initial?: boolean) => Promise<void>;
      }
    ).syncBatch(channelId, true);

    expect(saveNotes).toHaveBeenCalledTimes(1);
    expect(channelSyncCompleted).toHaveBeenCalledWith(channelId);
    // sync state is cleared once the chain has nothing left to schedule
    expect(store.map.has(`sync_state_${channelId}`)).toBe(false);
  });

  it("does not signal channelSyncCompleted while more pages remain", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: { cursor: null, initialSync: true },
    });
    const channelSyncCompleted = vi.fn();
    const { granola } = makeGranola({ store, integrations: { channelSyncCompleted } });
    const listNotes = vi.fn().mockResolvedValue({
      data: [noteSummary("n1")],
      cursor: "cursor2",
      hasMore: true,
    });
    const getNote = vi.fn().mockResolvedValue(fullNote("n1"));
    (granola as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, getNote });
    (granola as unknown as { callback: unknown }).callback = vi
      .fn()
      .mockResolvedValue("cb");

    await (
      granola as unknown as {
        syncBatch: (id: string, initial?: boolean) => Promise<void>;
      }
    ).syncBatch(channelId, true);

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    const state = store.map.get(`sync_state_${channelId}`) as { cursor: string };
    expect(state.cursor).toBe("cursor2");
  });

  it("does not signal channelSyncCompleted when an incremental (non-initial) sync completes", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: { cursor: null, initialSync: false },
    });
    const channelSyncCompleted = vi.fn();
    const saveNotes = vi.fn().mockResolvedValue(undefined);
    const { granola } = makeGranola({
      store,
      integrations: { channelSyncCompleted, saveNotes },
    });
    const listNotes = vi
      .fn()
      .mockResolvedValue({ data: [noteSummary("n1")], cursor: null, hasMore: false });
    const getNote = vi.fn().mockResolvedValue(fullNote("n1"));
    (granola as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, getNote });

    await (
      granola as unknown as {
        syncBatch: (id: string, initial?: boolean) => Promise<void>;
      }
    ).syncBatch(channelId, false);

    expect(channelSyncCompleted).not.toHaveBeenCalled();
  });

  it("does not signal channelSyncCompleted when sync state is missing (already cleared)", async () => {
    const store = makeStore();
    const channelSyncCompleted = vi.fn();
    const { granola } = makeGranola({ store, integrations: { channelSyncCompleted } });
    const listNotes = vi.fn();
    (granola as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes });

    await (
      granola as unknown as {
        syncBatch: (id: string, initial?: boolean) => Promise<void>;
      }
    ).syncBatch(channelId, true);

    expect(listNotes).not.toHaveBeenCalled();
    expect(channelSyncCompleted).not.toHaveBeenCalled();
  });
});

describe("syncBatch auth errors", () => {
  function authError(status: number) {
    return new GranolaApiError(
      `Granola API ${status} Forbidden on /notes?page_size=30 — {"code":"SUBSCRIPTION_INACTIVE","message":"Workspace subscription is not active."}`,
      status
    );
  }

  it("flags needs-reauth and stops (no reschedule, no throw) on a 403", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: { cursor: null, initialSync: true },
    });
    const markNeedsReauth = vi.fn().mockResolvedValue(undefined);
    const { granola, tasks } = makeGranola({
      store,
      integrations: { markNeedsReauth },
    });
    const listNotes = vi.fn().mockRejectedValue(authError(403));
    (granola as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, getNote: vi.fn() });

    await (granola as unknown as {
      syncBatch: (id: string, initial?: boolean) => Promise<void>;
    }).syncBatch(channelId, true);

    expect(markNeedsReauth).toHaveBeenCalledWith(channelId);
    expect(tasks.runTask).not.toHaveBeenCalled();
  });

  it("flags needs-reauth when a per-note fetch 401s", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: { cursor: null, initialSync: true },
    });
    const markNeedsReauth = vi.fn().mockResolvedValue(undefined);
    const { granola } = makeGranola({ store, integrations: { markNeedsReauth } });
    const listNotes = vi.fn().mockResolvedValue({
      data: [noteSummary("n1")],
      cursor: null,
      hasMore: false,
    });
    const getNote = vi.fn().mockRejectedValue(authError(401));
    (granola as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, getNote });

    await (granola as unknown as {
      syncBatch: (id: string, initial?: boolean) => Promise<void>;
    }).syncBatch(channelId, true);

    expect(markNeedsReauth).toHaveBeenCalledWith(channelId);
  });

  it("rethrows non-auth errors without flagging", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: { cursor: null, initialSync: true },
    });
    const markNeedsReauth = vi.fn().mockResolvedValue(undefined);
    const { granola } = makeGranola({ store, integrations: { markNeedsReauth } });
    const listNotes = vi
      .fn()
      .mockRejectedValue(new GranolaApiError("Granola API 500 on /notes", 500));
    (granola as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, getNote: vi.fn() });

    await expect(
      (granola as unknown as {
        syncBatch: (id: string, initial?: boolean) => Promise<void>;
      }).syncBatch(channelId, true)
    ).rejects.toThrow("500");
    expect(markNeedsReauth).not.toHaveBeenCalled();
  });

  it("still skips a pending-summary per-note failure and ingests the rest", async () => {
    // Guards the pre-existing behavior: a non-auth per-note error is skipped.
    const store = makeStore({
      [`sync_state_${channelId}`]: { cursor: null, initialSync: true },
    });
    const saveNotes = vi.fn().mockResolvedValue(undefined);
    const { granola } = makeGranola({ store, integrations: { saveNotes } });
    const listNotes = vi.fn().mockResolvedValue({
      data: [noteSummary("n1"), noteSummary("n2")],
      cursor: null,
      hasMore: false,
    });
    const getNote = vi
      .fn()
      .mockImplementation(async (id: string) => {
        if (id === "n1") throw new GranolaApiError("Granola API 422 on /notes/n1", 422);
        return fullNote(id);
      });
    (granola as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ listNotes, getNote });

    await (granola as unknown as {
      syncBatch: (id: string, initial?: boolean) => Promise<void>;
    }).syncBatch(channelId, true);

    expect(saveNotes).toHaveBeenCalledTimes(1);
  });
});
