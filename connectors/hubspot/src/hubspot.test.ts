import { describe, expect, it, vi } from "vitest";
import { HubSpot, buildDealStatuses } from "./hubspot";
import type { HubSpotObject, HubSpotPipeline } from "./hubspot-api";

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
    list: vi.fn(async (prefix: string) =>
      [...map.keys()].filter((k) => k.startsWith(prefix))
    ),
    acquireLock: vi.fn(async (key: string) => {
      if (locks.has(key)) return false;
      locks.add(key);
      return true;
    }),
    releaseLock: vi.fn(async (key: string) => void locks.delete(key)),
  };
}

function makeHubSpot(
  opts: {
    store?: ReturnType<typeof makeStore>;
    integrations?: Record<string, unknown>;
    tasks?: Record<string, unknown>;
  } = {}
): HubSpot {
  const tools = {
    store: opts.store ?? makeStore(),
    integrations: {
      get: vi.fn().mockResolvedValue({ token: "tok" }),
      saveLink: vi.fn().mockResolvedValue("thread-1"),
      archiveLinks: vi.fn().mockResolvedValue(undefined),
      channelSyncCompleted: vi.fn().mockResolvedValue(undefined),
      ...opts.integrations,
    },
    tasks: {
      runTask: vi.fn(),
      scheduleRecurring: vi.fn(),
      cancelScheduledTask: vi.fn(),
      ...opts.tasks,
    },
  };
  return new HubSpot("twist-1" as never, { getTools: () => tools } as never);
}

/** All five independent initial-sync chains started by onChannelEnabled. */
const ALL_TYPES = ["contacts", "companies", "deals", "notes", "tasks"];

function seedState(overrides: Record<string, unknown> = {}) {
  return {
    after: null,
    batchNumber: 1,
    itemsProcessed: 0,
    initialSync: true,
    ...overrides,
  };
}

function makeObject(
  id: string,
  properties: Record<string, string | null> = {},
  associations?: HubSpotObject["associations"]
): HubSpotObject {
  return {
    id,
    properties,
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-02T00:00:00Z",
    ...(associations ? { associations } : {}),
  };
}

function makeContact(id: string): HubSpotObject {
  return makeObject(id, {
    firstname: "Grace",
    lastname: "Hopper",
    email: "grace@example.com",
    createdate: "2026-01-01T00:00:00Z",
  });
}

function makeDeal(id: string): HubSpotObject {
  return makeObject(id, {
    dealname: "Big Deal",
    amount: "12500",
    deal_currency_code: "USD",
    dealstage: "stage-1",
    pipeline: "pipe-1",
    createdate: "2026-01-01T00:00:00Z",
    hubspot_owner_id: "9",
    hs_created_by_user_id: "77",
  });
}

/** Store seed that skips hub-id and owner-map fetches in sync paths. */
function seededMaps() {
  return {
    hub_id: "424242",
    owners_map: {
      "owner:9": { name: "Ada Lovelace", email: "ada@example.com", accountId: "user:77" },
      "user:77": { name: "Ada Lovelace", email: "ada@example.com", accountId: "user:77" },
    },
  };
}

function setAPI(hs: HubSpot, api: Record<string, unknown>) {
  (hs as unknown as { getAPI: unknown }).getAPI = vi
    .fn()
    .mockResolvedValue(api);
}

function callSyncBatch(hs: HubSpot, type: string): Promise<void> {
  return (
    hs as unknown as { syncBatch: (t: string) => Promise<void> }
  ).syncBatch(type);
}

function emptyPage() {
  return { results: [] };
}

describe("initial-sync completion across the five batch chains", () => {
  it("does NOT call channelSyncCompleted after only one of five chains finishes", async () => {
    const store = makeStore({
      ...seededMaps(),
      initial_sync_pending: [...ALL_TYPES],
      sync_state_deals: seedState(),
    });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const saveLink = vi.fn().mockResolvedValue("t1");
    const hs = makeHubSpot({ store, integrations: { channelSyncCompleted, saveLink } });
    setAPI(hs, {
      listObjects: vi.fn().mockResolvedValue({ results: [makeDeal("d1")] }),
    });

    await callSyncBatch(hs, "deals");

    expect(saveLink).toHaveBeenCalledTimes(1);
    expect(channelSyncCompleted).not.toHaveBeenCalled();
    expect(store.map.get("initial_sync_pending")).toEqual([
      "contacts",
      "companies",
      "notes",
      "tasks",
    ]);
    expect(store.map.has("sync_state_deals")).toBe(false);
  });

  it("calls channelSyncCompleted once the fifth (final) chain finishes", async () => {
    const store = makeStore({
      ...seededMaps(),
      // The other four chains already reported completion — only "notes"
      // is still outstanding.
      initial_sync_pending: ["notes"],
      sync_state_notes: seedState(),
    });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const hs = makeHubSpot({ store, integrations: { channelSyncCompleted } });
    setAPI(hs, {
      listObjects: vi.fn().mockResolvedValue(emptyPage()),
    });

    await callSyncBatch(hs, "notes");

    expect(channelSyncCompleted).toHaveBeenCalledTimes(1);
    expect(channelSyncCompleted).toHaveBeenCalledWith("hubspot");
    expect(store.map.has("initial_sync_pending")).toBe(false);
  });

  it("does not signal completion while more pages remain in a chain", async () => {
    const store = makeStore({
      ...seededMaps(),
      initial_sync_pending: [...ALL_TYPES],
      sync_state_contacts: seedState(),
    });
    const channelSyncCompleted = vi.fn();
    const saveLink = vi.fn().mockResolvedValue("t1");
    const runTask = vi.fn();
    const hs = makeHubSpot({
      store,
      integrations: { channelSyncCompleted, saveLink },
      tasks: { runTask },
    });
    setAPI(hs, {
      listObjects: vi.fn().mockResolvedValue({
        results: [makeContact("c1")],
        paging: { next: { after: "cursor-2" } },
      }),
    });
    (hs as unknown as { callback: unknown }).callback = vi
      .fn()
      .mockResolvedValue("cb");

    await callSyncBatch(hs, "contacts");

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    // Pending set is untouched — the "contacts" chain hasn't finished yet.
    expect(store.map.get("initial_sync_pending")).toEqual([...ALL_TYPES]);
    const state = store.map.get("sync_state_contacts") as { after: string };
    expect(state.after).toBe("cursor-2");
    expect(runTask).toHaveBeenCalledTimes(1);
  });

  it("does not signal completion for an incremental (non-initial) sync", async () => {
    const store = makeStore({
      ...seededMaps(),
      initial_sync_pending: ["deals"],
      sync_state_deals: seedState({ initialSync: false }),
    });
    const channelSyncCompleted = vi.fn();
    const hs = makeHubSpot({ store, integrations: { channelSyncCompleted } });
    setAPI(hs, {
      listObjects: vi.fn().mockResolvedValue(emptyPage()),
    });

    await callSyncBatch(hs, "deals");

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    expect(store.map.get("initial_sync_pending")).toEqual(["deals"]);
  });

  it("skips signaling when the pending set was never initialized", async () => {
    const store = makeStore({
      ...seededMaps(),
      sync_state_deals: seedState(),
    });
    const channelSyncCompleted = vi.fn();
    const hs = makeHubSpot({ store, integrations: { channelSyncCompleted } });
    setAPI(hs, {
      listObjects: vi.fn().mockResolvedValue(emptyPage()),
    });

    await callSyncBatch(hs, "deals");

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    // This chain's own pagination state still clears normally — only the
    // (skipped, unsafe) completion signal is affected.
    expect(store.map.has("sync_state_deals")).toBe(false);
    expect(store.map.has("initial_sync_pending")).toBe(false);
  });
});

describe("markSyncTypeComplete lock contention", () => {
  it("retries when the pending-set lock is briefly held, without dropping the completion", async () => {
    const store = makeStore({ initial_sync_pending: ["deals"] });
    store.acquireLock = vi
      .fn()
      .mockResolvedValueOnce(false)
      .mockResolvedValueOnce(true);
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const hs = makeHubSpot({ store, integrations: { channelSyncCompleted } });

    vi.stubGlobal(
      "setTimeout",
      ((fn: () => void) => {
        fn();
        return 0 as unknown as ReturnType<typeof setTimeout>;
      }) as typeof setTimeout
    );

    try {
      await (
        hs as unknown as {
          markSyncTypeComplete: (t: string) => Promise<void>;
        }
      ).markSyncTypeComplete("deals");
    } finally {
      vi.unstubAllGlobals();
    }

    expect(channelSyncCompleted).toHaveBeenCalledTimes(1);
    expect(store.map.has("initial_sync_pending")).toBe(false);
  });
});

describe("record → link conversion", () => {
  it("saves a deal link with source, url, status, author, and assignee", async () => {
    const store = makeStore({
      ...seededMaps(),
      sync_state_deals: seedState(),
      initial_sync_pending: [...ALL_TYPES],
    });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const hs = makeHubSpot({ store, integrations: { saveLink } });
    setAPI(hs, {
      listObjects: vi.fn().mockResolvedValue({ results: [makeDeal("d1")] }),
    });

    await callSyncBatch(hs, "deals");

    expect(saveLink).toHaveBeenCalledTimes(1);
    const link = saveLink.mock.calls[0][0];
    expect(link.source).toBe("hubspot:424242:deal:d1");
    expect(link.type).toBe("deal");
    expect(link.title).toBe("Big Deal");
    expect(link.status).toBe("stage-1");
    expect(link.preview).toBe("USD 12,500");
    expect(link.channelId).toBe("hubspot");
    expect(link.meta).toEqual({
      hubspotObjectType: "deals",
      hubspotRecordId: "d1",
      syncProvider: "hubspot",
      channelId: "hubspot",
    });
    expect(link.sourceUrl).toBe(
      "https://app.hubspot.com/contacts/424242/record/0-3/d1"
    );
    // Author = creator (hs_created_by_user_id 77), assignee = owner (id 9);
    // both resolve to the same person under one canonical accountId.
    expect(link.author).toEqual({
      name: "Ada Lovelace",
      email: "ada@example.com",
      source: { accountId: "user:77" },
    });
    expect(link.assignee).toEqual({
      name: "Ada Lovelace",
      email: "ada@example.com",
      source: { accountId: "user:77" },
    });
    // Initial sync marks records read + unarchived.
    expect(link.unread).toBe(false);
    expect(link.archived).toBe(false);
  });

  it("attributes records without a creating user to no author", async () => {
    const store = makeStore({
      ...seededMaps(),
      sync_state_contacts: seedState({ initialSync: false }),
    });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const hs = makeHubSpot({ store, integrations: { saveLink } });
    setAPI(hs, {
      listObjects: vi.fn().mockResolvedValue({ results: [makeContact("c1")] }),
    });

    await callSyncBatch(hs, "contacts");

    const link = saveLink.mock.calls[0][0];
    expect(link.title).toBe("Grace Hopper");
    expect(link.author).toBeNull();
    // Incremental sync omits the unread/archived overrides.
    expect(link.unread).toBeUndefined();
    expect(link.archived).toBeUndefined();
  });
});

describe("engagements as notes on parent threads", () => {
  it("attaches a note engagement to every associated record's thread", async () => {
    const store = makeStore({
      ...seededMaps(),
      sync_state_notes: seedState(),
      initial_sync_pending: [...ALL_TYPES],
    });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const hs = makeHubSpot({ store, integrations: { saveLink } });
    const note = makeObject(
      "n1",
      {
        hs_note_body: "<p>Talked to Grace</p>",
        hs_timestamp: "2026-01-03T00:00:00Z",
        hs_created_by_user_id: "77",
      },
      {
        contacts: { results: [{ id: "c1", type: "note_to_contact" }] },
        deals: { results: [{ id: "d1", type: "note_to_deal" }] },
      }
    );
    const batchReadObjects = vi
      .fn()
      .mockImplementation(async (type: string, ids: string[]) => {
        if (type === "contacts" && ids.includes("c1")) return [makeContact("c1")];
        if (type === "deals" && ids.includes("d1")) return [makeDeal("d1")];
        return [];
      });
    setAPI(hs, {
      listObjects: vi.fn().mockResolvedValue({ results: [note] }),
      batchReadObjects,
    });

    await callSyncBatch(hs, "notes");

    // One saveLink per associated parent, each carrying the note.
    expect(saveLink).toHaveBeenCalledTimes(2);
    const sources = saveLink.mock.calls.map((c) => c[0].source).sort();
    expect(sources).toEqual([
      "hubspot:424242:contact:c1",
      "hubspot:424242:deal:d1",
    ]);
    for (const call of saveLink.mock.calls) {
      expect(call[0].notes).toEqual([
        {
          key: "note-n1",
          content: "<p>Talked to Grace</p>",
          contentType: "html",
          created: new Date("2026-01-03T00:00:00Z"),
          author: {
            name: "Ada Lovelace",
            email: "ada@example.com",
            source: { accountId: "user:77" },
          },
        },
      ]);
    }
  });

  it("skips parents deleted upstream (absent from the batch read)", async () => {
    const store = makeStore({
      ...seededMaps(),
      sync_state_notes: seedState({ initialSync: false }),
    });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const hs = makeHubSpot({ store, integrations: { saveLink } });
    const note = makeObject(
      "n1",
      { hs_note_body: "<p>orphaned</p>" },
      { contacts: { results: [{ id: "gone", type: "note_to_contact" }] } }
    );
    setAPI(hs, {
      listObjects: vi.fn().mockResolvedValue({ results: [note] }),
      batchReadObjects: vi.fn().mockResolvedValue([]),
    });

    await callSyncBatch(hs, "notes");

    expect(saveLink).not.toHaveBeenCalled();
  });

  it("renders tasks as bolded subject notes with a completion marker", async () => {
    const store = makeStore({
      ...seededMaps(),
      sync_state_tasks: seedState({ initialSync: false }),
    });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const hs = makeHubSpot({ store, integrations: { saveLink } });
    const task = makeObject(
      "tk1",
      {
        hs_task_subject: "Follow up <soon>",
        hs_task_body: "<p>details</p>",
        hs_task_status: "COMPLETED",
      },
      { deals: { results: [{ id: "d1", type: "task_to_deal" }] } }
    );
    setAPI(hs, {
      listObjects: vi.fn().mockResolvedValue({ results: [task] }),
      batchReadObjects: vi.fn().mockResolvedValue([makeDeal("d1")]),
    });

    await callSyncBatch(hs, "tasks");

    expect(saveLink).toHaveBeenCalledTimes(1);
    const note = saveLink.mock.calls[0][0].notes[0];
    expect(note.key).toBe("task-tk1");
    expect(note.content).toBe(
      "<p><strong>Follow up &lt;soon&gt; ✅</strong></p><p>details</p>"
    );
    expect(note.contentType).toBe("html");
  });
});

describe("incremental poll", () => {
  it("does nothing when the channel is disabled", async () => {
    const store = makeStore({});
    const hs = makeHubSpot({ store });
    const listObjects = vi.fn();
    setAPI(hs, { listObjects });

    await (hs as unknown as { pollChanges: () => Promise<void> }).pollChanges();

    expect(listObjects).not.toHaveBeenCalled();
  });

  it("upserts modified records and advances the per-type high-water mark", async () => {
    const past = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const modified = new Date(Date.now() - 30 * 60 * 1000).toISOString();
    const store = makeStore({
      ...seededMaps(),
      sync_enabled: true,
      poll_since_deals: past,
    });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const hs = makeHubSpot({ store, integrations: { saveLink } });
    const deal = makeDeal("d1");
    deal.properties.hs_lastmodifieddate = modified;
    const searchModifiedSince = vi
      .fn()
      .mockResolvedValue({ results: [deal] });
    setAPI(hs, { searchModifiedSince });

    await (
      hs as unknown as {
        pollType: (api: unknown, t: string) => Promise<void>;
      }
    ).pollType(
      await (hs as unknown as { getAPI: () => Promise<unknown> }).getAPI(),
      "deals"
    );

    expect(searchModifiedSince).toHaveBeenCalledWith(
      "deals",
      expect.objectContaining({ since: new Date(past) })
    );
    expect(saveLink).toHaveBeenCalledTimes(1);
    // Poll saves are incremental — no unread/archived overrides.
    expect(saveLink.mock.calls[0][0].unread).toBeUndefined();
    // High-water mark advanced to just past the newest modified item
    // (older than the lag floor, so used as-is +1ms).
    expect(store.map.get("poll_since_deals")).toBe(
      new Date(new Date(modified).getTime() + 1).toISOString()
    );
  });

  it("never advances the mark past the search-index lag floor", async () => {
    const past = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const justNow = new Date().toISOString();
    const store = makeStore({
      ...seededMaps(),
      sync_enabled: true,
      poll_since_deals: past,
    });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const hs = makeHubSpot({ store, integrations: { saveLink } });
    const deal = makeDeal("d1");
    deal.properties.hs_lastmodifieddate = justNow;
    setAPI(hs, {
      searchModifiedSince: vi.fn().mockResolvedValue({ results: [deal] }),
    });

    await (
      hs as unknown as {
        pollType: (api: unknown, t: string) => Promise<void>;
      }
    ).pollType(
      await (hs as unknown as { getAPI: () => Promise<unknown> }).getAPI(),
      "deals"
    );

    const nextSince = new Date(store.map.get("poll_since_deals") as string);
    // The stored mark stays >= 1 lag buffer behind the just-modified item.
    expect(nextSince.getTime()).toBeLessThan(new Date(justNow).getTime());
  });

  it("re-fetches polled engagements with associations before saving", async () => {
    const past = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const store = makeStore({
      ...seededMaps(),
      sync_enabled: true,
      poll_since_notes: past,
    });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const hs = makeHubSpot({ store, integrations: { saveLink } });
    const bare = makeObject("n1", { hs_note_body: "<p>hi</p>" });
    const withAssoc = makeObject(
      "n1",
      { hs_note_body: "<p>hi</p>" },
      { contacts: { results: [{ id: "c1", type: "note_to_contact" }] } }
    );
    const getObject = vi.fn().mockResolvedValue(withAssoc);
    setAPI(hs, {
      searchModifiedSince: vi.fn().mockResolvedValue({ results: [bare] }),
      getObject,
      batchReadObjects: vi.fn().mockResolvedValue([makeContact("c1")]),
    });

    await (
      hs as unknown as {
        pollType: (api: unknown, t: string) => Promise<void>;
      }
    ).pollType(
      await (hs as unknown as { getAPI: () => Promise<unknown> }).getAPI(),
      "notes"
    );

    expect(getObject).toHaveBeenCalledWith(
      "notes",
      "n1",
      expect.any(Array),
      ["contacts", "companies", "deals"]
    );
    expect(saveLink).toHaveBeenCalledTimes(1);
    expect(saveLink.mock.calls[0][0].source).toBe("hubspot:424242:contact:c1");
  });
});

describe("write-backs", () => {
  it("onLinkUpdated writes the deal stage with its pipeline", async () => {
    const hs = makeHubSpot({ store: makeStore(seededMaps()) });
    const updateObject = vi.fn().mockResolvedValue(makeDeal("d1"));
    setAPI(hs, {
      listPipelines: vi.fn().mockResolvedValue([
        {
          id: "pipe-1",
          label: "Sales",
          displayOrder: 0,
          stages: [{ id: "stage-2", label: "Won", displayOrder: 1 }],
        },
      ] satisfies HubSpotPipeline[]),
      updateObject,
    });

    await hs.onLinkUpdated({
      type: "deal",
      status: "stage-2",
      meta: { hubspotRecordId: "d1" },
    } as never);

    expect(updateObject).toHaveBeenCalledWith("deals", "d1", {
      dealstage: "stage-2",
      pipeline: "pipe-1",
    });
  });

  it("onNoteCreated posts a note engagement and returns the stored body as baseline", async () => {
    const hs = makeHubSpot({ store: makeStore(seededMaps()) });
    const createNote = vi.fn().mockResolvedValue(
      makeObject("n9", { hs_note_body: "stored body" })
    );
    setAPI(hs, { createNote });

    const result = await hs.onNoteCreated(
      { content: "Hello **world**" } as never,
      { meta: { hubspotObjectType: "deals", hubspotRecordId: "d1" } } as never
    );

    expect(createNote).toHaveBeenCalledTimes(1);
    const [body, , parentType, parentId] = createNote.mock.calls[0];
    expect(parentType).toBe("deals");
    expect(parentId).toBe("d1");
    expect(body).toBe("Hello world");
    expect(result).toEqual({
      key: "note-n9",
      externalContent: "stored body",
    });
  });

  it("onNoteUpdated patches the note body and refreshes the baseline", async () => {
    const hs = makeHubSpot({ store: makeStore(seededMaps()) });
    const updateObject = vi.fn().mockResolvedValue(
      makeObject("n9", { hs_note_body: "updated body" })
    );
    setAPI(hs, { updateObject });

    const result = await hs.onNoteUpdated(
      { key: "note-n9", content: "edited" } as never,
      { meta: { hubspotObjectType: "deals", hubspotRecordId: "d1" } } as never
    );

    expect(updateObject).toHaveBeenCalledWith("notes", "n9", {
      hs_note_body: "edited",
    });
    expect(result).toEqual({ externalContent: "updated body" });
  });

  it("onNoteUpdated ignores task-keyed notes (tasks are synced read-only)", async () => {
    const hs = makeHubSpot({ store: makeStore(seededMaps()) });
    const updateObject = vi.fn();
    setAPI(hs, { updateObject });

    const result = await hs.onNoteUpdated(
      { key: "task-tk1", content: "edited" } as never,
      { meta: { hubspotObjectType: "deals", hubspotRecordId: "d1" } } as never
    );

    expect(updateObject).not.toHaveBeenCalled();
    expect(result).toBeUndefined();
  });
});

describe("buildDealStatuses", () => {
  const pipelines: HubSpotPipeline[] = [
    {
      id: "pipe-1",
      label: "Sales",
      displayOrder: 0,
      stages: [
        { id: "s1", label: "Qualified", displayOrder: 0, metadata: { isClosed: "false", probability: "0.4" } },
        { id: "s2", label: "Won", displayOrder: 1, metadata: { isClosed: "true", probability: "1.0" } },
        { id: "s3", label: "Lost", displayOrder: 2, metadata: { isClosed: "true", probability: "0.0" } },
      ],
    },
  ];

  it("maps open/won/lost stages to inProgress/done/cancelled", () => {
    const statuses = buildDealStatuses(pipelines);
    expect(statuses).toEqual([
      { status: "s1", label: "Qualified", icon: "inProgress" },
      { status: "s2", label: "Won", icon: "done", done: true },
      { status: "s3", label: "Lost", icon: "cancelled", done: true },
    ]);
  });

  it("prefixes stage labels with the pipeline name when there are several pipelines", () => {
    const second: HubSpotPipeline = {
      id: "pipe-2",
      label: "Partnerships",
      displayOrder: 1,
      stages: [
        { id: "p1", label: "Qualified", displayOrder: 0, metadata: { isClosed: false, probability: "0.5" } },
      ],
    };
    const statuses = buildDealStatuses([second, ...pipelines]);
    expect(statuses[0].label).toBe("Sales: Qualified");
    expect(statuses[3]).toEqual({
      status: "p1",
      label: "Partnerships: Qualified",
      icon: "inProgress",
    });
  });
});

describe("channel lifecycle", () => {
  it("onChannelEnabled schedules the poll, seeds baselines, and starts all five chains", async () => {
    const store = makeStore({});
    const runTask = vi.fn();
    const scheduleRecurring = vi.fn();
    const hs = makeHubSpot({ store, tasks: { runTask, scheduleRecurring } });
    (hs as unknown as { callback: unknown }).callback = vi
      .fn()
      .mockResolvedValue("cb");

    await hs.onChannelEnabled({ id: "hubspot", title: "HubSpot" } as never);

    expect(store.map.get("sync_enabled")).toBe(true);
    expect(store.map.get("initial_sync_pending")).toEqual([...ALL_TYPES]);
    for (const type of ALL_TYPES) {
      expect(store.map.has(`poll_since_${type}`)).toBe(true);
      expect(store.map.get(`sync_state_${type}`)).toEqual(seedState());
    }
    expect(scheduleRecurring).toHaveBeenCalledTimes(1);
    // One queued batch task per chain.
    expect(runTask).toHaveBeenCalledTimes(ALL_TYPES.length);
  });

  it("onChannelDisabled cancels the poll and clears per-channel state", async () => {
    const store = makeStore({
      sync_enabled: true,
      initial_sync_pending: [...ALL_TYPES],
      owners_map: {},
      sync_state_deals: seedState(),
      poll_since_deals: "2026-01-01T00:00:00Z",
    });
    const cancelScheduledTask = vi.fn();
    const hs = makeHubSpot({ store, tasks: { cancelScheduledTask } });

    await hs.onChannelDisabled({ id: "hubspot", title: "HubSpot" } as never);

    expect(cancelScheduledTask).toHaveBeenCalledWith("change-poll");
    expect(store.map.has("sync_enabled")).toBe(false);
    expect(store.map.has("initial_sync_pending")).toBe(false);
    expect(store.map.has("owners_map")).toBe(false);
    expect(store.map.has("sync_state_deals")).toBe(false);
    expect(store.map.has("poll_since_deals")).toBe(false);
  });
});
