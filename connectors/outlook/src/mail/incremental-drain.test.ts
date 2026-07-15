import { describe, expect, it, vi } from "vitest";

// Swap only the GraphMailApi class so the drain talks to a mock Graph client;
// keep every other real export from the module intact.
const { graphApi } = vi.hoisted(() => ({
  graphApi: {
    getMessage: vi.fn(),
    getConversationMessages: vi.fn(),
  },
}));

vi.mock("./graph-mail-api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./graph-mail-api")>();
  return { ...actual, GraphMailApi: vi.fn(() => graphApi) };
});

import {
  type OutlookMailSyncHost,
  PENDING_MSG_PREFIX,
  drainNotifiedMessagesFn,
  incrementalSyncBatchFn,
  migrateLegacyPendingMessagesFn,
  queueIncrementalSyncFn,
} from "./sync";

function makeHost(initial: Record<string, unknown> = {}): {
  host: OutlookMailSyncHost;
  map: Map<string, unknown>;
  scheduleDrain: ReturnType<typeof vi.fn>;
} {
  const map = new Map<string, unknown>([
    ["enabled_channels", ["inbox-folder"]],
    // Pre-cache well-known folders so the drain doesn't hit Graph for them.
    ["wellknown_folders", { inbox: "inbox-folder", drafts: "drafts-folder" }],
    ...Object.entries(initial),
  ]);
  const store = {
    get: vi.fn(async (k: string) => (map.has(k) ? map.get(k) : null)),
    set: vi.fn(async (k: string, v: unknown) => {
      map.set(k, v);
    }),
    setMany: vi.fn(async (entries: [string, unknown][]) => {
      for (const [k, v] of entries) map.set(k, v);
    }),
    clear: vi.fn(async (k: string) => {
      map.delete(k);
    }),
    list: vi.fn(async (p: string) =>
      [...map.keys()].filter((k) => k.startsWith(p)).sort()
    ),
    acquireLock: vi.fn(async () => true),
    releaseLock: vi.fn(async () => {}),
  };
  const scheduleDrain = vi.fn(async () => {});
  const host = {
    id: "twist-instance-1",
    set: store.set,
    setMany: store.setMany,
    get: store.get,
    clear: store.clear,
    tools: {
      store,
      integrations: {
        get: vi.fn(async () => ({ token: "tok", scopes: [] })),
        saveLink: vi.fn(async () => null),
        channelSyncCompleted: vi.fn(async () => {}),
        setThreadToDo: vi.fn(async () => {}),
      },
      files: { read: vi.fn() },
      network: { createWebhook: vi.fn(), deleteWebhook: vi.fn() },
    },
    scheduler: {
      onOutlookMailWebhook: undefined,
      setupMailboxSubscription: vi.fn(async () => {}),
      renewMailboxSubscription: vi.fn(async () => {}),
      scheduleMailboxRenewal: vi.fn(async () => {}),
      scheduleSelfHealCheck: vi.fn(async () => {}),
      cancelScheduledTask: vi.fn(async () => {}),
      scheduleDrain,
      queueRenewSubscription: vi.fn(async () => {}),
      requeueInitialSync: vi.fn(async () => {}),
    },
  } as unknown as OutlookMailSyncHost;
  return { host, map, scheduleDrain };
}

describe("queueIncrementalSyncFn / incrementalSyncBatchFn", () => {
  it("forward notified ids to the platform drain", async () => {
    const { host, scheduleDrain } = makeHost();

    await queueIncrementalSyncFn(host, ["m1", "m2"]);
    expect(scheduleDrain).toHaveBeenCalledWith(["m1", "m2"]);

    // Legacy entry point (already-queued callbacks) re-records the same way.
    await incrementalSyncBatchFn(host, ["m3"]);
    expect(scheduleDrain).toHaveBeenCalledWith(["m3"]);
  });
});

describe("migrateLegacyPendingMessagesFn", () => {
  it("re-records pre-drain pending state via the platform drain and clears it", async () => {
    const { host, map, scheduleDrain } = makeHost({
      [`${PENDING_MSG_PREFIX}old1`]: 2,
      incremental_state: { pendingMessageIds: [{ id: "old2", attempts: 1 }] },
    });

    await migrateLegacyPendingMessagesFn(host);

    expect(scheduleDrain).toHaveBeenCalledTimes(1);
    const migrated = scheduleDrain.mock.calls[0][0] as string[];
    expect(migrated.sort()).toEqual(["old1", "old2"]);
    expect(map.has(`${PENDING_MSG_PREFIX}old1`)).toBe(false);
    expect(map.get("incremental_state")).toEqual({});
  });

  it("is a no-op once migrated", async () => {
    const { host, scheduleDrain } = makeHost();
    await migrateLegacyPendingMessagesFn(host);
    expect(scheduleDrain).not.toHaveBeenCalled();
  });
});

describe("drainNotifiedMessagesFn", () => {
  it("returns retry for probe failures and nothing for skips", async () => {
    const { host } = makeHost();
    graphApi.getMessage.mockImplementation(async (id: string) => {
      if (id === "gone") return null; // hard-deleted upstream
      if (id === "draft") return { id, isDraft: true };
      if (id === "excluded")
        return { id, isDraft: false, parentFolderId: "drafts-folder" };
      if (id === "broken") throw new Error("boom");
      return { id, isDraft: false, conversationId: `conv-${id}` };
    });
    graphApi.getConversationMessages.mockResolvedValue([]);

    const result = await drainNotifiedMessagesFn(host, [
      "gone",
      "draft",
      "excluded",
      "broken",
      "ok",
    ]);

    // Only the probe FAILURE is retried; skips are released by the platform.
    expect(result).toEqual({ retry: ["broken"] });
  });

  it("no-ops on an empty slice", async () => {
    const { host } = makeHost();
    graphApi.getMessage.mockClear();

    const result = await drainNotifiedMessagesFn(host, []);

    expect(result).toBeUndefined();
    expect(graphApi.getMessage).not.toHaveBeenCalled();
  });

  it("returns undefined when every probe succeeds", async () => {
    const { host } = makeHost();
    graphApi.getMessage.mockResolvedValue(null);

    const result = await drainNotifiedMessagesFn(host, ["m1", "m2"]);

    expect(result).toBeUndefined();
  });
});
