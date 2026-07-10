import { describe, expect, it, vi } from "vitest";
import { Attio } from "./attio";
import type { AttioNote, AttioRecord, AttioTask } from "./attio-api";

/**
 * In-memory store backing `this.get` / `this.set` / `this.clear` (which
 * delegate to `this.tools.store`), plus a minimal lock implementation so
 * `markSyncTypeComplete`'s acquireLock/releaseLock guard is exercised
 * faithfully (a real held lock blocks a second acquirer).
 */
function makeStore(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(Object.entries(initial));
  const locks = new Set<string>();
  return {
    map,
    get: vi.fn(async (key: string) => (map.has(key) ? map.get(key) : null)),
    set: vi.fn(async (key: string, value: unknown) => void map.set(key, value)),
    clear: vi.fn(async (key: string) => void map.delete(key)),
    list: vi.fn(async (prefix: string) => [...map.keys()].filter((k) => k.startsWith(prefix))),
    acquireLock: vi.fn(async (key: string) => {
      if (locks.has(key)) return false;
      locks.add(key);
      return true;
    }),
    releaseLock: vi.fn(async (key: string) => void locks.delete(key)),
  };
}

function makeAttio(
  opts: {
    store?: ReturnType<typeof makeStore>;
    integrations?: Record<string, unknown>;
  } = {}
): Attio {
  const tools = {
    store: opts.store ?? makeStore(),
    integrations: {
      get: vi.fn().mockResolvedValue({ token: "tok" }),
      saveLink: vi.fn().mockResolvedValue("thread-1"),
      channelSyncCompleted: vi.fn().mockResolvedValue(undefined),
      ...opts.integrations,
    },
    tasks: { runTask: vi.fn() },
    network: {},
  };
  return new Attio("twist-1" as never, { getTools: () => tools } as never);
}

/** All five independent initial-sync chains started by onChannelEnabled. */
const ALL_TYPES = ["deals", "people", "companies", "tasks", "notes"];

function seedState(overrides: Record<string, unknown> = {}) {
  return {
    cursor: null,
    batchNumber: 1,
    recordsProcessed: 0,
    initialSync: true,
    ...overrides,
  };
}

function makeRecord(id: string): AttioRecord {
  return {
    id: { record_id: id, object_id: "obj", workspace_id: "ws1" },
    values: {},
    created_at: "2026-01-01T00:00:00Z",
  };
}

function makeTask(id: string): AttioTask {
  return {
    id: { task_id: id, workspace_id: "ws1" },
    content_plaintext: "A task",
    assignees: [],
    is_completed: false,
    deadline_at: null,
    created_at: "2026-01-01T00:00:00Z",
    linked_records: [],
  };
}

function makeNote(id: string): AttioNote {
  return {
    id: { note_id: id, workspace_id: "ws1" },
    parent_object: "companies",
    parent_record_id: "rec1",
    title: "A note",
    content_plaintext: "note body",
    created_by_actor: { type: "workspace-member", id: "wm1" },
    created_at: "2026-01-01T00:00:00Z",
  };
}

function callSyncBatch(attio: Attio, entityType: string): Promise<void> {
  return (attio as unknown as { syncBatch: (e: string) => Promise<void> }).syncBatch(
    entityType
  );
}

describe("initial-sync completion across the three/five batch chains", () => {
  it("does NOT call channelSyncCompleted after only one of five chains finishes", async () => {
    const store = makeStore({
      workspace_slug: "acme",
      initial_sync_pending: [...ALL_TYPES],
      sync_state_deals: seedState(),
    });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const saveLink = vi.fn().mockResolvedValue("t1");
    const attio = makeAttio({ store, integrations: { channelSyncCompleted, saveLink } });
    (attio as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({
      queryRecords: vi
        .fn()
        .mockResolvedValue({ data: [makeRecord("r1")], next_cursor: null }),
    });

    await callSyncBatch(attio, "deals");

    expect(saveLink).toHaveBeenCalledTimes(1);
    expect(channelSyncCompleted).not.toHaveBeenCalled();
    expect(store.map.get("initial_sync_pending")).toEqual([
      "people",
      "companies",
      "tasks",
      "notes",
    ]);
    expect(store.map.has("sync_state_deals")).toBe(false);
  });

  it("calls channelSyncCompleted once the fifth (final) chain finishes", async () => {
    const store = makeStore({
      workspace_slug: "acme",
      // deals/people/companies/tasks already reported completion — only
      // "notes" is still outstanding.
      initial_sync_pending: ["notes"],
      sync_state_notes: seedState(),
    });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const attio = makeAttio({ store, integrations: { channelSyncCompleted } });
    (attio as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({
      queryNotes: vi
        .fn()
        .mockResolvedValue({ data: [makeNote("n1")], next_cursor: null }),
    });

    await callSyncBatch(attio, "notes");

    expect(channelSyncCompleted).toHaveBeenCalledTimes(1);
    expect(channelSyncCompleted).toHaveBeenCalledWith("attio");
    expect(store.map.has("initial_sync_pending")).toBe(false);
  });

  it("progressively tracks all five chains and signals only after the last one completes", async () => {
    const store = makeStore({
      workspace_slug: "acme",
      initial_sync_pending: [...ALL_TYPES],
    });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const attio = makeAttio({ store, integrations: { channelSyncCompleted } });
    (attio as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({
      queryRecords: vi.fn().mockResolvedValue({ data: [], next_cursor: null }),
      queryTasks: vi.fn().mockResolvedValue({ data: [], next_cursor: null }),
      queryNotes: vi.fn().mockResolvedValue({ data: [], next_cursor: null }),
    });

    // Finish four of the five chains first — completion must NOT fire yet.
    for (const type of ["deals", "people", "companies", "tasks"]) {
      store.map.set(`sync_state_${type}`, seedState());
      await callSyncBatch(attio, type);
      expect(channelSyncCompleted).not.toHaveBeenCalled();
    }

    // The fifth and final chain finishes — completion fires exactly once.
    store.map.set("sync_state_notes", seedState());
    await callSyncBatch(attio, "notes");

    expect(channelSyncCompleted).toHaveBeenCalledTimes(1);
    expect(channelSyncCompleted).toHaveBeenCalledWith("attio");
  });

  it("does not signal completion while more pages remain in a chain", async () => {
    const store = makeStore({
      initial_sync_pending: [...ALL_TYPES],
      sync_state_tasks: seedState(),
    });
    const channelSyncCompleted = vi.fn();
    const attio = makeAttio({ store, integrations: { channelSyncCompleted } });
    (attio as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({
      queryTasks: vi
        .fn()
        .mockResolvedValue({ data: [makeTask("tk1")], next_cursor: "cursor2" }),
    });
    (attio as unknown as { callback: unknown }).callback = vi.fn().mockResolvedValue("cb");

    await callSyncBatch(attio, "tasks");

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    // Pending set is untouched — the "tasks" chain hasn't finished yet.
    expect(store.map.get("initial_sync_pending")).toEqual([...ALL_TYPES]);
    const state = store.map.get("sync_state_tasks") as { cursor: string };
    expect(state.cursor).toBe("cursor2");
  });

  it("does not signal completion for an incremental (non-initial) sync", async () => {
    const store = makeStore({
      workspace_slug: "acme",
      // "deals" is still mid initial-sync in the pending set — an
      // incremental re-sync pass must not touch that tracking.
      initial_sync_pending: ["deals"],
      sync_state_deals: seedState({ initialSync: false }),
    });
    const channelSyncCompleted = vi.fn();
    const attio = makeAttio({ store, integrations: { channelSyncCompleted } });
    (attio as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({
      queryRecords: vi.fn().mockResolvedValue({ data: [], next_cursor: null }),
    });

    await callSyncBatch(attio, "deals");

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    expect(store.map.get("initial_sync_pending")).toEqual(["deals"]);
  });

  it("skips signaling when the pending set was never initialized (pre-fix connection)", async () => {
    const store = makeStore({
      // No `initial_sync_pending` key at all — simulates a connection whose
      // five chains were started under pre-fix code that never wrote this
      // key. `get()` returns null (not []) for a missing key, and that must
      // be treated differently from "all five reported in": we can't tell
      // how many of the other four chains are still outstanding, so
      // signaling here would risk clearing the "Syncing…" indicator early.
      workspace_slug: "acme",
      sync_state_deals: seedState(),
    });
    const channelSyncCompleted = vi.fn();
    const saveLink = vi.fn().mockResolvedValue("t1");
    const attio = makeAttio({ store, integrations: { channelSyncCompleted, saveLink } });
    (attio as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({
      queryRecords: vi.fn().mockResolvedValue({ data: [], next_cursor: null }),
    });

    await callSyncBatch(attio, "deals");

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    // This chain's own pagination state still clears normally — only the
    // (skipped, unsafe) completion signal is affected.
    expect(store.map.has("sync_state_deals")).toBe(false);
    expect(store.map.has("initial_sync_pending")).toBe(false);
  });
});

describe("markSyncTypeComplete lock contention", () => {
  it("retries when the pending-set lock is briefly held by another chain, without dropping the completion", async () => {
    const store = makeStore({ initial_sync_pending: ["deals"] });
    // First acquire attempt reports the lock held by a concurrently
    // finishing chain; the second (retried) attempt succeeds.
    store.acquireLock = vi
      .fn()
      .mockResolvedValueOnce(false)
      .mockResolvedValueOnce(true);
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const attio = makeAttio({ store, integrations: { channelSyncCompleted } });

    vi.stubGlobal(
      "setTimeout",
      ((fn: () => void) => {
        fn();
        return 0 as unknown as ReturnType<typeof setTimeout>;
      }) as typeof setTimeout
    );

    try {
      await (
        attio as unknown as { markSyncTypeComplete: (t: string) => Promise<void> }
      ).markSyncTypeComplete("deals");
    } finally {
      vi.unstubAllGlobals();
    }

    expect(store.acquireLock).toHaveBeenCalledTimes(2);
    expect(channelSyncCompleted).toHaveBeenCalledWith("attio");
  });

  it("throws when the lock can never be acquired, and leaves sync_state intact for a future retry", async () => {
    const store = makeStore({
      workspace_slug: "acme",
      initial_sync_pending: [...ALL_TYPES],
      sync_state_deals: seedState(),
    });
    // Lock is always held by someone else — every acquire attempt fails.
    store.acquireLock = vi.fn().mockResolvedValue(false);
    const channelSyncCompleted = vi.fn();
    const attio = makeAttio({ store, integrations: { channelSyncCompleted } });
    (attio as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({
      queryRecords: vi.fn().mockResolvedValue({ data: [], next_cursor: null }),
    });

    vi.stubGlobal(
      "setTimeout",
      ((fn: () => void) => {
        fn();
        return 0 as unknown as ReturnType<typeof setTimeout>;
      }) as typeof setTimeout
    );

    try {
      await expect(callSyncBatch(attio, "deals")).rejects.toThrow(
        /failed to acquire initial_sync_pending_lock/
      );
    } finally {
      vi.unstubAllGlobals();
    }

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    // The throw must propagate BEFORE the caller's terminal-branch clear()
    // runs — otherwise this chain's sync_state is gone and it can never
    // re-enter this branch to actually record the completion, permanently
    // stranding "deals" in initial_sync_pending.
    expect(store.map.has("sync_state_deals")).toBe(true);
    expect(store.map.get("initial_sync_pending")).toEqual([...ALL_TYPES]);
  });
});
