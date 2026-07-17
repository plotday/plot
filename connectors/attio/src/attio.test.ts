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
    network?: Record<string, unknown>;
  } = {}
): Attio {
  const tools = {
    store: opts.store ?? makeStore(),
    integrations: {
      get: vi.fn().mockResolvedValue({ token: "tok" }),
      saveLink: vi.fn().mockResolvedValue("thread-1"),
      archiveLinks: vi.fn().mockResolvedValue(undefined),
      channelSyncCompleted: vi.fn().mockResolvedValue(undefined),
      ...opts.integrations,
    },
    tasks: { runTask: vi.fn() },
    network: {
      createWebhook: vi.fn().mockResolvedValue("https://hooks.example.com/h/tok1"),
      ...opts.network,
    },
  };
  return new Attio("twist-1" as never, { getTools: () => tools } as never);
}

/** All five independent initial-sync chains started by onChannelEnabled. */
const ALL_TYPES = ["deals", "people", "companies", "tasks", "notes"];

function seedState(overrides: Record<string, unknown> = {}) {
  return {
    offset: 0,
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

const valueMeta = {
  active_from: "2026-01-01T00:00:00Z",
  active_until: null,
  attribute_type: "text",
};

function makeCompanyRecord(id: string, name: string): AttioRecord {
  return {
    id: { record_id: id, object_id: "obj-companies", workspace_id: "ws1" },
    values: { name: [{ ...valueMeta, value: name }] },
    created_at: "2026-01-01T00:00:00Z",
  };
}

function makePersonRecord(id: string, fullName: string): AttioRecord {
  return {
    id: { record_id: id, object_id: "obj-people", workspace_id: "ws1" },
    values: {
      name: [{ ...valueMeta, full_name: fullName }],
      email_addresses: [{ ...valueMeta, email_address: "person@example.com" }],
    },
    created_at: "2026-01-01T00:00:00Z",
  };
}

/** An Error shaped like AttioAPI.request's failures, carrying the HTTP status. */
function apiError(status: number): Error {
  return Object.assign(new Error(`Attio API GET /x failed (${status}): nope`), {
    status,
  });
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
      queryRecords: vi.fn().mockResolvedValue({ data: [makeRecord("r1")] }),
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
      queryNotes: vi.fn().mockResolvedValue({ data: [makeNote("n1")] }),
      getRecord: vi
        .fn()
        .mockResolvedValue({ data: makeCompanyRecord("rec1", "Acme Corp") }),
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
      queryRecords: vi.fn().mockResolvedValue({ data: [] }),
      queryTasks: vi.fn().mockResolvedValue({ data: [] }),
      queryNotes: vi.fn().mockResolvedValue({ data: [] }),
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
    // A full page (page-size items) means more may remain — the chain must
    // continue, not complete. Attio's API returns no cursor; a full page is
    // the only continuation signal.
    const fullPage = Array.from({ length: 50 }, (_, i) => makeTask(`tk${i}`));
    (attio as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({
      queryTasks: vi.fn().mockResolvedValue({ data: fullPage }),
    });
    (attio as unknown as { callback: unknown }).callback = vi.fn().mockResolvedValue("cb");

    await callSyncBatch(attio, "tasks");

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    // Pending set is untouched — the "tasks" chain hasn't finished yet.
    expect(store.map.get("initial_sync_pending")).toEqual([...ALL_TYPES]);
    const state = store.map.get("sync_state_tasks") as { offset: number };
    expect(state.offset).toBe(50);
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
      queryRecords: vi.fn().mockResolvedValue({ data: [] }),
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
      queryRecords: vi.fn().mockResolvedValue({ data: [] }),
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
      queryRecords: vi.fn().mockResolvedValue({ data: [] }),
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

describe("offset pagination (Attio's API returns no cursor)", () => {
  it("continues to the next page when a full page of records returns", async () => {
    const store = makeStore({
      workspace_slug: "acme",
      initial_sync_pending: [...ALL_TYPES],
      sync_state_people: seedState(),
    });
    const channelSyncCompleted = vi.fn();
    const attio = makeAttio({ store, integrations: { channelSyncCompleted } });
    const fullPage = Array.from({ length: 50 }, (_, i) => makeRecord(`r${i}`));
    (attio as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({
      queryRecords: vi.fn().mockResolvedValue({ data: fullPage }),
    });
    (attio as unknown as { callback: unknown }).callback = vi
      .fn()
      .mockResolvedValue("cb");
    const runTask = (attio as unknown as { tools: { tasks: { runTask: unknown } } })
      .tools.tasks.runTask;

    await callSyncBatch(attio, "people");

    const state = store.map.get("sync_state_people") as {
      offset: number;
      batchNumber: number;
    };
    expect(state.offset).toBe(50);
    expect(state.batchNumber).toBe(2);
    expect(runTask).toHaveBeenCalledTimes(1);
    expect(channelSyncCompleted).not.toHaveBeenCalled();
  });

  it("requests the stored offset from the API", async () => {
    const store = makeStore({
      workspace_slug: "acme",
      sync_state_people: seedState({ offset: 100, batchNumber: 3 }),
    });
    const attio = makeAttio({ store });
    const queryRecords = vi.fn().mockResolvedValue({ data: [] });
    (attio as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ queryRecords });

    await callSyncBatch(attio, "people");

    expect(queryRecords).toHaveBeenCalledWith(
      "people",
      expect.objectContaining({ offset: 100, limit: 50 })
    );
  });

  it("finishes the chain on a partial page", async () => {
    const store = makeStore({
      workspace_slug: "acme",
      initial_sync_pending: ["people"],
      sync_state_people: seedState({ offset: 50, batchNumber: 2 }),
    });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const attio = makeAttio({ store, integrations: { channelSyncCompleted } });
    (attio as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({
      queryRecords: vi
        .fn()
        .mockResolvedValue({ data: [makeRecord("r50"), makeRecord("r51")] }),
    });

    await callSyncBatch(attio, "people");

    expect(channelSyncCompleted).toHaveBeenCalledWith("attio");
    expect(store.map.has("sync_state_people")).toBe(false);
  });

  it("continues notes pagination on a full page", async () => {
    const store = makeStore({
      workspace_slug: "acme",
      sync_state_notes: seedState(),
    });
    const attio = makeAttio({ store });
    // Empty-content notes are skipped before any parent fetch, isolating
    // the pagination behavior.
    const fullPage = Array.from({ length: 50 }, (_, i) => ({
      ...makeNote(`n${i}`),
      title: "",
      content_plaintext: "",
    }));
    const queryNotes = vi.fn().mockResolvedValue({ data: fullPage });
    (attio as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ queryNotes });
    (attio as unknown as { callback: unknown }).callback = vi
      .fn()
      .mockResolvedValue("cb");

    await callSyncBatch(attio, "notes");

    const state = store.map.get("sync_state_notes") as { offset: number };
    expect(state.offset).toBe(50);
  });
});

describe("note sync fetches the parent record", () => {
  function notesAttio(opts: {
    initialSync?: boolean;
    getRecord: ReturnType<typeof vi.fn>;
    saveLink?: ReturnType<typeof vi.fn>;
  }) {
    const store = makeStore({
      workspace_slug: "acme",
      sync_state_notes: seedState({ initialSync: opts.initialSync ?? true }),
    });
    const saveLink = opts.saveLink ?? vi.fn().mockResolvedValue("t1");
    const attio = makeAttio({ store, integrations: { saveLink } });
    (attio as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({
      queryNotes: vi.fn().mockResolvedValue({ data: [makeNote("n1")] }),
      getRecord: opts.getRecord,
    });
    return { attio, saveLink };
  }

  it("titles the parent thread from the fetched record", async () => {
    const getRecord = vi
      .fn()
      .mockResolvedValue({ data: makeCompanyRecord("rec1", "Acme Corp") });
    const { attio, saveLink } = notesAttio({ getRecord });

    await callSyncBatch(attio, "notes");

    expect(getRecord).toHaveBeenCalledWith("companies", "rec1");
    expect(saveLink).toHaveBeenCalledTimes(1);
    const link = saveLink.mock.calls[0][0];
    expect(link.title).toBe("Acme Corp");
    expect(link.type).toBe("company");
    expect(link.source).toBe("attio:ws1:company:rec1");
    expect(link.notes).toHaveLength(1);
    expect(link.notes[0].key).toBe("note-n1");
    expect(link.notes[0].content).toBe("**A note**\n\nnote body");
  });

  it("skips notes whose parent record no longer exists (404)", async () => {
    const getRecord = vi.fn().mockRejectedValue(apiError(404));
    const { attio, saveLink } = notesAttio({ getRecord });

    await callSyncBatch(attio, "notes");

    expect(saveLink).not.toHaveBeenCalled();
  });

  it("still fails on non-404 fetch errors", async () => {
    const getRecord = vi.fn().mockRejectedValue(apiError(500));
    const { attio, saveLink } = notesAttio({ getRecord });

    await expect(callSyncBatch(attio, "notes")).rejects.toThrow(/500/);
    expect(saveLink).not.toHaveBeenCalled();
  });

  it("marks the thread unread:false during initial sync", async () => {
    const getRecord = vi
      .fn()
      .mockResolvedValue({ data: makeCompanyRecord("rec1", "Acme Corp") });
    const { attio, saveLink } = notesAttio({ getRecord, initialSync: true });

    await callSyncBatch(attio, "notes");

    const link = saveLink.mock.calls[0][0];
    expect(link.unread).toBe(false);
    expect(link.archived).toBe(false);
  });

  it("omits the unread flag for incremental note sync", async () => {
    const getRecord = vi
      .fn()
      .mockResolvedValue({ data: makeCompanyRecord("rec1", "Acme Corp") });
    const { attio, saveLink } = notesAttio({ getRecord, initialSync: false });

    await callSyncBatch(attio, "notes");

    const link = saveLink.mock.calls[0][0];
    expect(link).not.toHaveProperty("unread");
    expect(link).not.toHaveProperty("archived");
  });
});

describe("task sync fetches linked parent records", () => {
  it("titles each linked thread from its fetched record and skips 404s", async () => {
    const store = makeStore({
      workspace_slug: "acme",
      sync_state_tasks: seedState({ initialSync: true }),
    });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const attio = makeAttio({ store, integrations: { saveLink } });
    const task = {
      ...makeTask("tk1"),
      linked_records: [
        { target_object: "people", target_record_id: "p1" },
        { target_object: "people", target_record_id: "gone" },
      ],
    };
    const getRecord = vi.fn(async (_slug: string, recordId: string) => {
      if (recordId === "gone") throw apiError(404);
      return { data: makePersonRecord(recordId, "Ada Lovelace") };
    });
    (attio as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({
      queryTasks: vi.fn().mockResolvedValue({ data: [task] }),
      getRecord,
    });

    await callSyncBatch(attio, "tasks");

    expect(saveLink).toHaveBeenCalledTimes(1);
    const link = saveLink.mock.calls[0][0];
    expect(link.title).toBe("Ada Lovelace");
    expect(link.source).toBe("attio:ws1:person:p1");
    expect(link.notes[0].key).toBe("task-tk1");
    expect(link.unread).toBe(false);
  });
});

describe("webhook event handling (batched, id-only payloads)", () => {
  function webhookAttio(store = makeStore({ workspace_slug: "acme" })) {
    const archiveLinks = vi.fn().mockResolvedValue(undefined);
    const saveLink = vi.fn().mockResolvedValue("t1");
    const attio = makeAttio({ store, integrations: { archiveLinks, saveLink } });
    const scheduleDrain = vi.fn().mockResolvedValue(undefined);
    (attio as unknown as { scheduleDrain: unknown }).scheduleDrain = scheduleDrain;
    return { attio, archiveLinks, saveLink, scheduleDrain };
  }

  function callOnWebhook(attio: Attio, body: unknown): Promise<void> {
    return (
      attio as unknown as { onWebhook: (r: { body: unknown }) => Promise<void> }
    ).onWebhook({ body });
  }

  it("queues record events from a batched payload for drain", async () => {
    const { attio, scheduleDrain } = webhookAttio();

    await callOnWebhook(attio, {
      webhook_id: "wh1",
      events: [
        {
          event_type: "record.created",
          id: { workspace_id: "ws1", object_id: "obj-1", record_id: "rec-1" },
          actor: { type: "workspace-member", id: "wm1" },
        },
        {
          event_type: "record.updated",
          id: { workspace_id: "ws1", object_id: "obj-1", record_id: "rec-2" },
          actor: { type: "workspace-member", id: "wm1" },
        },
      ],
    });

    expect(scheduleDrain).toHaveBeenCalledTimes(1);
    const [, , options] = scheduleDrain.mock.calls[0];
    expect(options).toEqual({ ids: ["record:obj-1:rec-1", "record:obj-1:rec-2"] });
  });

  it("archives links inline for record.deleted events", async () => {
    const { attio, archiveLinks, scheduleDrain } = webhookAttio();

    await callOnWebhook(attio, {
      webhook_id: "wh1",
      events: [
        {
          event_type: "record.deleted",
          id: { workspace_id: "ws1", object_id: "obj-1", record_id: "rec-9" },
          actor: { type: "workspace-member", id: "wm1" },
        },
      ],
    });

    expect(archiveLinks).toHaveBeenCalledWith(
      expect.objectContaining({
        meta: expect.objectContaining({ attioRecordId: "rec-9" }),
      })
    );
    expect(scheduleDrain).not.toHaveBeenCalled();
  });

  it("queues note and task events for drain", async () => {
    const { attio, scheduleDrain } = webhookAttio();

    await callOnWebhook(attio, {
      webhook_id: "wh1",
      events: [
        {
          event_type: "note.created",
          id: { workspace_id: "ws1", note_id: "n-1" },
          parent_object_id: "obj-1",
          parent_record_id: "rec-1",
          actor: { type: "workspace-member", id: "wm1" },
        },
        {
          event_type: "note-content.updated",
          id: { workspace_id: "ws1", note_id: "n-2" },
          parent_object_id: "obj-1",
          parent_record_id: "rec-1",
          actor: { type: "workspace-member", id: "wm1" },
        },
        {
          event_type: "task.created",
          id: { workspace_id: "ws1", task_id: "t-1" },
          actor: { type: "workspace-member", id: "wm1" },
        },
      ],
    });

    const [, , options] = scheduleDrain.mock.calls[0];
    expect(options).toEqual({ ids: ["note:n-1", "note:n-2", "task:t-1"] });
  });

  it("ignores payloads with no recognized events", async () => {
    const { attio, scheduleDrain, archiveLinks } = webhookAttio();

    await callOnWebhook(attio, { webhook_id: "wh1", events: [] });
    await callOnWebhook(attio, { some: "other shape" });
    await callOnWebhook(attio, undefined);

    expect(scheduleDrain).not.toHaveBeenCalled();
    expect(archiveLinks).not.toHaveBeenCalled();
  });
});

describe("webhook drain", () => {
  function drainAttio(api: Record<string, unknown>, store = makeStore({ workspace_slug: "acme" })) {
    const saveLink = vi.fn().mockResolvedValue("t1");
    const attio = makeAttio({ store, integrations: { saveLink } });
    (attio as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue(api);
    const drain = (
      attio as unknown as { drainWebhookEvents: (ids: string[]) => Promise<void> }
    ).drainWebhookEvents.bind(attio);
    return { attio, saveLink, drain };
  }

  it("fetches records by object id, resolves the slug, and upserts without unread", async () => {
    const listObjects = vi.fn().mockResolvedValue([
      { id: { object_id: "obj-people", workspace_id: "ws1" }, api_slug: "people" },
    ]);
    const getRecord = vi
      .fn()
      .mockResolvedValue({ data: makePersonRecord("rec-1", "Ada Lovelace") });
    const { saveLink, drain } = drainAttio({ listObjects, getRecord });

    await drain(["record:obj-people:rec-1"]);

    expect(getRecord).toHaveBeenCalledWith("obj-people", "rec-1");
    expect(saveLink).toHaveBeenCalledTimes(1);
    const link = saveLink.mock.calls[0][0];
    expect(link.title).toBe("Ada Lovelace");
    expect(link.type).toBe("person");
    // Webhook-driven syncs are incremental — unread must be left unset.
    expect(link).not.toHaveProperty("unread");
  });

  it("skips records whose object type is not synced", async () => {
    const listObjects = vi.fn().mockResolvedValue([
      { id: { object_id: "obj-projects", workspace_id: "ws1" }, api_slug: "projects" },
    ]);
    const getRecord = vi.fn();
    const { saveLink, drain } = drainAttio({ listObjects, getRecord });

    await drain(["record:obj-projects:rec-1"]);

    expect(getRecord).not.toHaveBeenCalled();
    expect(saveLink).not.toHaveBeenCalled();
  });

  it("skips records deleted before the drain ran (404)", async () => {
    const listObjects = vi.fn().mockResolvedValue([
      { id: { object_id: "obj-people", workspace_id: "ws1" }, api_slug: "people" },
    ]);
    const getRecord = vi.fn().mockRejectedValue(apiError(404));
    const { saveLink, drain } = drainAttio({ listObjects, getRecord });

    await drain(["record:obj-people:rec-1"]);

    expect(saveLink).not.toHaveBeenCalled();
  });

  it("caches the object-id-to-slug map in the store", async () => {
    const store = makeStore({
      workspace_slug: "acme",
      attio_object_slugs: { "obj-people": "people" },
    });
    const listObjects = vi.fn();
    const getRecord = vi
      .fn()
      .mockResolvedValue({ data: makePersonRecord("rec-1", "Ada Lovelace") });
    const { saveLink, drain } = drainAttio({ listObjects, getRecord }, store);

    await drain(["record:obj-people:rec-1"]);

    expect(listObjects).not.toHaveBeenCalled();
    expect(saveLink).toHaveBeenCalledTimes(1);
  });

  it("fetches notes by id and saves them on their fetched parent", async () => {
    const getNote = vi.fn().mockResolvedValue({ data: makeNote("n-1") });
    const getRecord = vi
      .fn()
      .mockResolvedValue({ data: makeCompanyRecord("rec1", "Acme Corp") });
    const { saveLink, drain } = drainAttio({ getNote, getRecord });

    await drain(["note:n-1"]);

    expect(getNote).toHaveBeenCalledWith("n-1");
    const link = saveLink.mock.calls[0][0];
    expect(link.title).toBe("Acme Corp");
    expect(link.notes[0].key).toBe("note-n-1");
    expect(link).not.toHaveProperty("unread");
  });

  it("fetches tasks by id and saves them on their linked records", async () => {
    const task = {
      ...makeTask("t-1"),
      linked_records: [{ target_object: "companies", target_record_id: "rec1" }],
    };
    const getTask = vi.fn().mockResolvedValue({ data: task });
    const getRecord = vi
      .fn()
      .mockResolvedValue({ data: makeCompanyRecord("rec1", "Acme Corp") });
    const { saveLink, drain } = drainAttio({ getTask, getRecord });

    await drain(["task:t-1"]);

    expect(getTask).toHaveBeenCalledWith("t-1");
    const link = saveLink.mock.calls[0][0];
    expect(link.title).toBe("Acme Corp");
    expect(link.notes[0].key).toBe("task-t-1");
  });

  it("skips notes deleted before the drain ran (404)", async () => {
    const getNote = vi.fn().mockRejectedValue(apiError(404));
    const { saveLink, drain } = drainAttio({ getNote });

    await drain(["note:n-1"]);

    expect(saveLink).not.toHaveBeenCalled();
  });
});

describe("webhook setup", () => {
  it("subscribes to record, note, and task events", async () => {
    const store = makeStore({ workspace_slug: "acme" });
    const attio = makeAttio({ store });
    const createWebhook = vi
      .fn()
      .mockResolvedValue({ data: { id: { webhook_id: "wh-new" } } });
    (attio as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ createWebhook, deleteWebhook: vi.fn() });

    await (
      attio as unknown as { setupAttioWebhook: () => Promise<void> }
    ).setupAttioWebhook();

    const [, subscriptions] = createWebhook.mock.calls[0];
    const types = (subscriptions as Array<{ event_type: string }>).map(
      (s) => s.event_type
    );
    expect(types).toEqual(
      expect.arrayContaining([
        "record.created",
        "record.updated",
        "record.deleted",
        "note.created",
        "note-content.updated",
        "task.created",
        "task.updated",
      ])
    );
    expect(store.map.get("webhook_id")).toBe("wh-new");
  });

  it("replaces a previously registered webhook instead of stacking a duplicate", async () => {
    const store = makeStore({ workspace_slug: "acme", webhook_id: "wh-old" });
    const attio = makeAttio({ store });
    const deleteWebhook = vi.fn().mockResolvedValue(undefined);
    const createWebhook = vi
      .fn()
      .mockResolvedValue({ data: { id: { webhook_id: "wh-new" } } });
    (attio as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ createWebhook, deleteWebhook });

    await (
      attio as unknown as { setupAttioWebhook: () => Promise<void> }
    ).setupAttioWebhook();

    expect(deleteWebhook).toHaveBeenCalledWith("wh-old");
    expect(store.map.get("webhook_id")).toBe("wh-new");
  });

  it("propagates registration failures so the task queue can retry", async () => {
    const store = makeStore({ workspace_slug: "acme" });
    const attio = makeAttio({ store });
    (attio as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({
      createWebhook: vi.fn().mockRejectedValue(apiError(500)),
      deleteWebhook: vi.fn(),
    });

    await expect(
      (
        attio as unknown as { setupAttioWebhook: () => Promise<void> }
      ).setupAttioWebhook()
    ).rejects.toThrow(/500/);
  });

  it("skips registration for localhost webhook URLs", async () => {
    const store = makeStore({ workspace_slug: "acme" });
    const attio = makeAttio({
      store,
      network: {
        createWebhook: vi.fn().mockResolvedValue("http://localhost:8787/hook/x"),
      },
    });
    const createWebhook = vi.fn();
    (attio as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockReturnValue({ createWebhook, deleteWebhook: vi.fn() });

    await (
      attio as unknown as { setupAttioWebhook: () => Promise<void> }
    ).setupAttioWebhook();

    expect(createWebhook).not.toHaveBeenCalled();
  });
});
