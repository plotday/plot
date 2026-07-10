import { describe, expect, it, vi } from "vitest";
import { Airtable } from "./airtable";
import type { AirtableRecord, AirtableTable } from "./airtable-api";

function makeStore(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(Object.entries(initial));
  return {
    map,
    get: vi.fn(async (k: string) => (map.has(k) ? map.get(k) : null)),
    set: vi.fn(async (k: string, v: unknown) => void map.set(k, v)),
    clear: vi.fn(async (k: string) => void map.delete(k)),
    list: vi.fn(async (p: string) => [...map.keys()].filter((k) => k.startsWith(p))),
  };
}

function makeAirtable(
  opts: {
    store?: ReturnType<typeof makeStore>;
    integrations?: Record<string, unknown>;
    network?: Record<string, unknown>;
  } = {}
): Airtable {
  const tools = {
    store: opts.store ?? makeStore(),
    integrations: {
      get: vi.fn().mockResolvedValue({ token: "tok" }),
      saveLink: vi.fn().mockResolvedValue("thread-1"),
      channelSyncCompleted: vi.fn().mockResolvedValue(undefined),
      ...opts.integrations,
    },
    network: { createWebhook: vi.fn(), ...opts.network },
  };
  return new Airtable("twist-1" as never, { getTools: () => tools } as never);
}

const baseId = "base1";

// A minimal detected task table with no assignee/status/notes fields — the
// tests below only exercise pagination and completion signaling, not field
// mapping, so the extra detail is intentionally omitted.
const detectedTable = {
  tableId: "tbl1",
  tableName: "Tasks",
  primaryFieldId: "fld1",
  primaryFieldName: "Name",
  assigneeFieldId: null,
  assigneeFieldName: null,
  assigneeFieldType: null,
  dueDateFieldId: null,
  dueDateFieldName: null,
  statusFieldId: null,
  statusFieldName: null,
  statusFieldType: null,
  doneOptionName: null,
  todoOptionName: null,
  notesFieldId: null,
  notesFieldName: null,
};

function record(id: string): AirtableRecord {
  return { id, createdTime: "2026-01-01T00:00:00Z", fields: { Name: `Task ${id}` } };
}

describe("syncBatch", () => {
  it("signals channelSyncCompleted when the last page of the last table is reached (initial sync)", async () => {
    const store = makeStore({
      [`sync_enabled_${baseId}`]: true,
      [`sync_state_${baseId}`]: { tableIndex: 0, offset: null, initialSync: true },
      [`task_tables_${baseId}`]: [detectedTable],
    });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const saveLink = vi.fn().mockResolvedValue("t1");
    const airtable = makeAirtable({ store, integrations: { channelSyncCompleted, saveLink } });
    const listRecords = vi
      .fn()
      .mockResolvedValue({ records: [record("rec1")], offset: undefined });
    (airtable as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockResolvedValue({ listRecords });

    await (airtable as unknown as { syncBatch: (b: string) => Promise<void> }).syncBatch(baseId);

    expect(saveLink).toHaveBeenCalledTimes(1);
    expect(channelSyncCompleted).toHaveBeenCalledWith(baseId);
    // sync state is cleared once the chain has nothing left to schedule
    expect(store.map.has(`sync_state_${baseId}`)).toBe(false);
  });

  it("does not signal channelSyncCompleted while more pages remain", async () => {
    const store = makeStore({
      [`sync_enabled_${baseId}`]: true,
      [`sync_state_${baseId}`]: { tableIndex: 0, offset: null, initialSync: true },
      [`task_tables_${baseId}`]: [detectedTable],
    });
    const channelSyncCompleted = vi.fn();
    const airtable = makeAirtable({ store, integrations: { channelSyncCompleted } });
    const listRecords = vi
      .fn()
      .mockResolvedValue({ records: [record("rec1")], offset: "cursor2" });
    (airtable as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockResolvedValue({ listRecords });
    (airtable as unknown as { callback: unknown }).callback = vi.fn().mockResolvedValue("cb");
    (airtable as unknown as { runTask: unknown }).runTask = vi.fn().mockResolvedValue(undefined);

    await (airtable as unknown as { syncBatch: (b: string) => Promise<void> }).syncBatch(baseId);

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    const state = store.map.get(`sync_state_${baseId}`) as { offset: string };
    expect(state.offset).toBe("cursor2");
  });

  it("does not signal channelSyncCompleted when an incremental (non-initial) sync completes", async () => {
    const store = makeStore({
      [`sync_enabled_${baseId}`]: true,
      [`sync_state_${baseId}`]: { tableIndex: 0, offset: null, initialSync: false },
      [`task_tables_${baseId}`]: [detectedTable],
    });
    const channelSyncCompleted = vi.fn();
    const saveLink = vi.fn().mockResolvedValue("t1");
    const airtable = makeAirtable({ store, integrations: { channelSyncCompleted, saveLink } });
    const listRecords = vi
      .fn()
      .mockResolvedValue({ records: [record("rec1")], offset: undefined });
    (airtable as unknown as { getAPI: unknown }).getAPI = vi
      .fn()
      .mockResolvedValue({ listRecords });

    await (airtable as unknown as { syncBatch: (b: string) => Promise<void> }).syncBatch(baseId);

    expect(channelSyncCompleted).not.toHaveBeenCalled();
  });
});

describe("detectAndSync", () => {
  it("signals channelSyncCompleted when the base has no task-shaped tables (initial sync)", async () => {
    const store = makeStore({ [`sync_enabled_${baseId}`]: true });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const airtable = makeAirtable({ store, integrations: { channelSyncCompleted } });
    // No collaborator/status field on the only table → scoreTable filters it
    // out, so refreshTaskTables resolves an empty detected list and the
    // batch chain (syncBatch) never starts.
    const listTables: AirtableTable[] = [
      {
        id: "tbl1",
        name: "Notes",
        primaryFieldId: "fld1",
        fields: [{ id: "fld1", name: "Name", type: "singleLineText" }],
      },
    ];
    (airtable as unknown as { getAPI: unknown }).getAPI = vi.fn().mockResolvedValue({
      listTables: vi.fn().mockResolvedValue(listTables),
    });

    await (
      airtable as unknown as { detectAndSync: (b: string, i: boolean) => Promise<void> }
    ).detectAndSync(baseId, true);

    expect(channelSyncCompleted).toHaveBeenCalledWith(baseId);
    expect(store.map.has(`sync_state_${baseId}`)).toBe(false);
  });

  it("does not signal channelSyncCompleted for a no-op incremental re-detect", async () => {
    const store = makeStore({ [`sync_enabled_${baseId}`]: true });
    const channelSyncCompleted = vi.fn();
    const airtable = makeAirtable({ store, integrations: { channelSyncCompleted } });
    const listTables: AirtableTable[] = [
      {
        id: "tbl1",
        name: "Notes",
        primaryFieldId: "fld1",
        fields: [{ id: "fld1", name: "Name", type: "singleLineText" }],
      },
    ];
    (airtable as unknown as { getAPI: unknown }).getAPI = vi.fn().mockResolvedValue({
      listTables: vi.fn().mockResolvedValue(listTables),
    });

    await (
      airtable as unknown as { detectAndSync: (b: string, i: boolean) => Promise<void> }
    ).detectAndSync(baseId, false);

    expect(channelSyncCompleted).not.toHaveBeenCalled();
  });
});
