import { describe, expect, it, vi } from "vitest";
import { Fellow } from "./fellow";
import type { FellowNote } from "./fellow-api";

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

describe("syncBatch", () => {
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
});
