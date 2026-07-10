import { afterEach, describe, expect, it, vi } from "vitest";

// Swap only the GraphApi class + syncChannelMessages so the connector talks to
// a mock Graph client; keep every other real export from the module intact
// (transformChannelThread/transformDmThread are exercised indirectly).
const { graphApi, syncChannelMessages } = vi.hoisted(() => ({
  graphApi: {
    getChats: vi.fn(),
    getChatMessages: vi.fn(),
  },
  syncChannelMessages: vi.fn(),
}));

vi.mock("./graph-api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./graph-api")>();
  return {
    ...actual,
    GraphApi: vi.fn(() => graphApi),
    syncChannelMessages,
  };
});

import { MsTeams } from "./ms-teams";

afterEach(() => {
  vi.clearAllMocks();
});

/**
 * In-memory store backing `this.get` / `this.set` / `this.clear` (which
 * delegate to `this.tools.store`), plus a minimal lock implementation so
 * `markDmSyncComplete`'s acquireLock/releaseLock guard is exercised
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

function makeMsTeams(
  opts: {
    store?: ReturnType<typeof makeStore>;
    integrations?: Record<string, unknown>;
  } = {}
): MsTeams {
  const tools = {
    store: opts.store ?? makeStore(),
    integrations: {
      get: vi.fn().mockResolvedValue({ token: "tok" }),
      saveLink: vi.fn().mockResolvedValue("thread-1"),
      channelSyncCompleted: vi.fn().mockResolvedValue(undefined),
      ...opts.integrations,
    },
    tasks: { runTask: vi.fn().mockResolvedValue(undefined) },
    callbacks: { create: vi.fn().mockResolvedValue("cb-token") },
    network: {},
  };
  return new MsTeams("twist-1" as never, { getTools: () => tools } as never);
}

function callSyncBatch(
  msTeams: MsTeams,
  batchNumber: number,
  mode: "full" | "incremental",
  channelId: string,
  initialSync?: boolean
): Promise<void> {
  return (
    msTeams as unknown as {
      syncBatch: (
        b: number,
        m: "full" | "incremental",
        c: string,
        i?: boolean
      ) => Promise<void>;
    }
  ).syncBatch(batchNumber, mode, channelId, initialSync);
}

function callSyncDmSpaces(
  msTeams: MsTeams,
  initialSync?: boolean
): Promise<void> {
  return (
    msTeams as unknown as { syncDmSpaces: (i?: boolean) => Promise<void> }
  ).syncDmSpaces(initialSync);
}

function callSyncDmBatch(
  msTeams: MsTeams,
  batchNumber: number,
  chatId: string,
  initialSync?: boolean
): Promise<void> {
  return (
    msTeams as unknown as {
      syncDmBatch: (
        b: number,
        c: string,
        i?: boolean
      ) => Promise<void>;
    }
  ).syncDmBatch(batchNumber, chatId, initialSync);
}

const channelId = "channel-1";

describe("channel syncBatch — initial-sync completion", () => {
  it("signals channelSyncCompleted when the last page is reached (initial sync)", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: { channelId, initialSync: true },
      [`team_for_channel_${channelId}`]: "team-1",
    });
    const channelSyncCompletedMock = vi.fn().mockResolvedValue(undefined);
    const msTeams = makeMsTeams({
      store,
      integrations: { channelSyncCompleted: channelSyncCompletedMock },
    });
    syncChannelMessages.mockResolvedValue({
      threads: [],
      state: { channelId, more: false, initialSync: true },
    });

    await callSyncBatch(msTeams, 1, "full", channelId, true);

    expect(channelSyncCompletedMock).toHaveBeenCalledWith(channelId);
    expect(store.map.has(`sync_state_${channelId}`)).toBe(false);
  });

  it("does not signal channelSyncCompleted while more pages remain", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: { channelId, initialSync: true },
      [`team_for_channel_${channelId}`]: "team-1",
    });
    const channelSyncCompletedMock = vi.fn();
    const msTeams = makeMsTeams({
      store,
      integrations: { channelSyncCompleted: channelSyncCompletedMock },
    });
    syncChannelMessages.mockResolvedValue({
      threads: [],
      state: { channelId, more: true, cursor: "next", initialSync: true },
    });

    await callSyncBatch(msTeams, 1, "full", channelId, true);

    expect(channelSyncCompletedMock).not.toHaveBeenCalled();
    // sync state is preserved (updated to the next page's cursor) — not cleared
    expect(store.map.has(`sync_state_${channelId}`)).toBe(true);
  });

  it("does not signal channelSyncCompleted when an incremental (webhook-driven) sync completes", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: { channelId, initialSync: false },
      [`team_for_channel_${channelId}`]: "team-1",
    });
    const channelSyncCompletedMock = vi.fn();
    const msTeams = makeMsTeams({
      store,
      integrations: { channelSyncCompleted: channelSyncCompletedMock },
    });
    syncChannelMessages.mockResolvedValue({
      threads: [],
      state: { channelId, more: false, initialSync: false },
    });

    await callSyncBatch(msTeams, 1, "incremental", channelId, false);

    expect(channelSyncCompletedMock).not.toHaveBeenCalled();
    // Incremental mode never clears/tracks sync_state (only "full" mode does).
  });

  it("does not signal channelSyncCompleted when the sync batch limit is reached", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: { channelId, initialSync: true },
      [`team_for_channel_${channelId}`]: "team-1",
    });
    const channelSyncCompletedMock = vi.fn();
    const msTeams = makeMsTeams({
      store,
      integrations: { channelSyncCompleted: channelSyncCompletedMock },
    });

    await callSyncBatch(msTeams, 51, "full", channelId, true);

    expect(channelSyncCompletedMock).not.toHaveBeenCalled();
    expect(syncChannelMessages).not.toHaveBeenCalled();
  });
});

describe("DM syncDmSpaces / syncDmBatch — initial-sync completion", () => {
  it("signals channelSyncCompleted immediately when there are no DM chats to sync", async () => {
    const store = makeStore();
    const channelSyncCompletedMock = vi.fn().mockResolvedValue(undefined);
    const msTeams = makeMsTeams({
      store,
      integrations: { channelSyncCompleted: channelSyncCompletedMock },
    });
    graphApi.getChats.mockResolvedValue([]);

    await callSyncDmSpaces(msTeams, true);

    expect(channelSyncCompletedMock).toHaveBeenCalledWith(
      "__direct_messages__"
    );
  });

  it("does NOT signal after only one of several DM chats finishes", async () => {
    const store = makeStore({
      dm_initial_sync_pending: ["chat-1", "chat-2"],
      "sync_state_dm_chat-1": { channelId: "chat-1", initialSync: true },
    });
    const channelSyncCompletedMock = vi.fn().mockResolvedValue(undefined);
    const msTeams = makeMsTeams({
      store,
      integrations: {
        channelSyncCompleted: channelSyncCompletedMock,
        get: vi.fn().mockResolvedValue({ token: "tok" }),
      },
    });
    graphApi.getChatMessages.mockResolvedValue({ value: [] });

    await callSyncDmBatch(msTeams, 1, "chat-1", true);

    expect(channelSyncCompletedMock).not.toHaveBeenCalled();
    expect(store.map.get("dm_initial_sync_pending")).toEqual(["chat-2"]);
  });

  it("signals channelSyncCompleted once the last outstanding DM chat finishes", async () => {
    const store = makeStore({
      dm_initial_sync_pending: ["chat-2"],
      "sync_state_dm_chat-2": { channelId: "chat-2", initialSync: true },
    });
    const channelSyncCompletedMock = vi.fn().mockResolvedValue(undefined);
    const msTeams = makeMsTeams({
      store,
      integrations: { channelSyncCompleted: channelSyncCompletedMock },
    });
    graphApi.getChatMessages.mockResolvedValue({ value: [] });

    await callSyncDmBatch(msTeams, 1, "chat-2", true);

    expect(channelSyncCompletedMock).toHaveBeenCalledTimes(1);
    expect(channelSyncCompletedMock).toHaveBeenCalledWith(
      "__direct_messages__"
    );
    expect(store.map.has("dm_initial_sync_pending")).toBe(false);
  });

  it("does not signal completion while more pages remain in a DM chat's own pagination", async () => {
    const store = makeStore({
      dm_initial_sync_pending: ["chat-1"],
      "sync_state_dm_chat-1": { channelId: "chat-1", initialSync: true },
    });
    const channelSyncCompletedMock = vi.fn();
    const msTeams = makeMsTeams({
      store,
      integrations: { channelSyncCompleted: channelSyncCompletedMock },
    });
    graphApi.getChatMessages.mockResolvedValue({
      value: [],
      "@odata.nextLink": "https://graph.microsoft.com/next",
    });

    await callSyncDmBatch(msTeams, 1, "chat-1", true);

    expect(channelSyncCompletedMock).not.toHaveBeenCalled();
    expect(store.map.get("dm_initial_sync_pending")).toEqual(["chat-1"]);
  });

  it("does not signal completion for an incremental (non-initial) DM sync", async () => {
    const store = makeStore({
      dm_initial_sync_pending: ["chat-1"],
      "sync_state_dm_chat-1": { channelId: "chat-1", initialSync: false },
    });
    const channelSyncCompletedMock = vi.fn();
    const msTeams = makeMsTeams({
      store,
      integrations: { channelSyncCompleted: channelSyncCompletedMock },
    });
    graphApi.getChatMessages.mockResolvedValue({ value: [] });

    await callSyncDmBatch(msTeams, 1, "chat-1", false);

    expect(channelSyncCompletedMock).not.toHaveBeenCalled();
    // The pending set (belonging to some other, still-outstanding initial
    // sync) must be untouched by an incremental pass.
    expect(store.map.get("dm_initial_sync_pending")).toEqual(["chat-1"]);
  });

  it("skips signaling when the pending set was never initialized (pre-fix connection)", async () => {
    const store = makeStore({
      "sync_state_dm_chat-1": { channelId: "chat-1", initialSync: true },
    });
    const channelSyncCompletedMock = vi.fn();
    const msTeams = makeMsTeams({
      store,
      integrations: { channelSyncCompleted: channelSyncCompletedMock },
    });
    graphApi.getChatMessages.mockResolvedValue({ value: [] });

    await callSyncDmBatch(msTeams, 1, "chat-1", true);

    expect(channelSyncCompletedMock).not.toHaveBeenCalled();
    // This chat's own pagination state still clears normally — only the
    // (skipped, unsafe) completion signal is affected.
    expect(store.map.has("sync_state_dm_chat-1")).toBe(false);
  });
});

describe("markDmSyncComplete lock contention", () => {
  it("retries when the pending-set lock is briefly held by another chat's chain, without dropping the completion", async () => {
    const store = makeStore({ dm_initial_sync_pending: ["chat-1"] });
    store.acquireLock = vi
      .fn()
      .mockResolvedValueOnce(false)
      .mockResolvedValueOnce(true);
    const channelSyncCompletedMock = vi.fn().mockResolvedValue(undefined);
    const msTeams = makeMsTeams({
      store,
      integrations: { channelSyncCompleted: channelSyncCompletedMock },
    });

    vi.stubGlobal(
      "setTimeout",
      ((fn: () => void) => {
        fn();
        return 0 as unknown as ReturnType<typeof setTimeout>;
      }) as typeof setTimeout
    );

    try {
      await (
        msTeams as unknown as {
          markDmSyncComplete: (id: string) => Promise<void>;
        }
      ).markDmSyncComplete("chat-1");
    } finally {
      vi.unstubAllGlobals();
    }

    expect(store.acquireLock).toHaveBeenCalledTimes(2);
    expect(channelSyncCompletedMock).toHaveBeenCalledWith(
      "__direct_messages__"
    );
  });

  it("throws when the lock can never be acquired, and leaves sync_state intact for a future retry", async () => {
    const store = makeStore({
      dm_initial_sync_pending: ["chat-1", "chat-2"],
      "sync_state_dm_chat-1": { channelId: "chat-1", initialSync: true },
    });
    store.acquireLock = vi.fn().mockResolvedValue(false);
    const channelSyncCompletedMock = vi.fn();
    const msTeams = makeMsTeams({
      store,
      integrations: { channelSyncCompleted: channelSyncCompletedMock },
    });
    graphApi.getChatMessages.mockResolvedValue({ value: [] });

    vi.stubGlobal(
      "setTimeout",
      ((fn: () => void) => {
        fn();
        return 0 as unknown as ReturnType<typeof setTimeout>;
      }) as typeof setTimeout
    );

    try {
      await expect(callSyncDmBatch(msTeams, 1, "chat-1", true)).rejects.toThrow(
        /failed to acquire dm_initial_sync_pending_lock/
      );
    } finally {
      vi.unstubAllGlobals();
    }

    expect(channelSyncCompletedMock).not.toHaveBeenCalled();
    // The throw must propagate BEFORE the caller's terminal-branch clear()
    // runs — otherwise this chat's sync_state is gone and it can never
    // re-enter this branch to actually record the completion, permanently
    // stranding "chat-1" in dm_initial_sync_pending.
    expect(store.map.has("sync_state_dm_chat-1")).toBe(true);
    expect(store.map.get("dm_initial_sync_pending")).toEqual([
      "chat-1",
      "chat-2",
    ]);
  });
});
