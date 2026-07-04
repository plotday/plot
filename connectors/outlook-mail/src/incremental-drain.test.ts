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
  MAX_INCREMENTAL_MESSAGES_PER_BATCH,
  MAX_MESSAGE_FETCH_ATTEMPTS,
  PENDING_MSG_PREFIX,
  incrementalSyncBatchFn,
  queueIncrementalSyncFn,
} from "./sync";

function makeHost(initial: Record<string, unknown> = {}): {
  host: OutlookMailSyncHost;
  map: Map<string, unknown>;
  scheduleIncrementalSyncDrain: ReturnType<typeof vi.fn>;
} {
  const map = new Map<string, unknown>([
    ["enabled_channels", ["inbox-folder"]],
    // Pre-cache well-known folders so the drain doesn't hit Graph for them.
    ["wellknown_folders", { inbox: "inbox-folder" }],
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
  const scheduleIncrementalSyncDrain = vi.fn(async () => {});
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
      scheduleIncrementalSyncDrain,
      queueRenewSubscription: vi.fn(async () => {}),
      requeueInitialSync: vi.fn(async () => {}),
    },
  } as unknown as OutlookMailSyncHost;
  return { host, map, scheduleIncrementalSyncDrain };
}

const pendingKeysIn = (map: Map<string, unknown>) =>
  [...map.keys()].filter((k) => k.startsWith(PENDING_MSG_PREFIX)).sort();

describe("queueIncrementalSyncFn", () => {
  it("persists one pending key per notified id, then schedules the coalesced drain", async () => {
    const { host, map, scheduleIncrementalSyncDrain } = makeHost();

    await queueIncrementalSyncFn(host, ["m1", "m2"]);

    expect(pendingKeysIn(map)).toEqual([
      `${PENDING_MSG_PREFIX}m1`,
      `${PENDING_MSG_PREFIX}m2`,
    ]);
    expect(scheduleIncrementalSyncDrain).toHaveBeenCalledTimes(1);
  });

  it("schedules the drain even with no ids (renewal-style nudge)", async () => {
    const { host, scheduleIncrementalSyncDrain } = makeHost();
    await queueIncrementalSyncFn(host, []);
    expect(scheduleIncrementalSyncDrain).toHaveBeenCalledTimes(1);
  });
});

describe("incrementalSyncBatchFn — bounded coalesced drain", () => {
  it("probes at most MAX_INCREMENTAL_MESSAGES_PER_BATCH and schedules a continuation for the rest", async () => {
    const total = MAX_INCREMENTAL_MESSAGES_PER_BATCH + 5;
    const initial = Object.fromEntries(
      Array.from({ length: total }, (_, i) => [
        // Zero-pad so lexicographic list order is deterministic.
        `${PENDING_MSG_PREFIX}m${String(i).padStart(3, "0")}`,
        0,
      ])
    );
    const { host, map, scheduleIncrementalSyncDrain } = makeHost(initial);
    // 404 for every probe: nothing to ingest, keys are simply consumed.
    graphApi.getMessage.mockResolvedValue(null);

    await incrementalSyncBatchFn(host, []);

    expect(graphApi.getMessage).toHaveBeenCalledTimes(
      MAX_INCREMENTAL_MESSAGES_PER_BATCH
    );
    // Processed keys cleared; overflow retained for the continuation.
    expect(pendingKeysIn(map)).toHaveLength(5);
    expect(scheduleIncrementalSyncDrain).toHaveBeenCalledTimes(1);
  });

  it("persists argument ids before processing so a dying pass loses nothing", async () => {
    const { host, map } = makeHost();
    // Seed write happens before probing; make the probe blow up the pass.
    graphApi.getMessage.mockRejectedValue(new Error("boom"));

    await incrementalSyncBatchFn(host, ["m1"]);

    // Probe failed → attempts bumped, key retained for retry.
    expect(map.get(`${PENDING_MSG_PREFIX}m1`)).toBe(1);
  });

  it("migrates legacy incremental_state.pendingMessageIds into pending keys", async () => {
    const { host, map } = makeHost({
      incremental_state: { pendingMessageIds: [{ id: "old1", attempts: 2 }] },
    });
    graphApi.getMessage.mockResolvedValue(null);

    await incrementalSyncBatchFn(host, []);

    // Legacy state cleared; the id flowed through the new pending-key path
    // (processed this pass since it fits the cap).
    expect(map.get("incremental_state")).toEqual({});
    expect(graphApi.getMessage).toHaveBeenCalledWith(
      "old1",
      "id,conversationId,parentFolderId,isDraft"
    );
  });

  it("drops a message after exhausting its fetch attempts", async () => {
    const { host, map } = makeHost({
      [`${PENDING_MSG_PREFIX}poison`]: MAX_MESSAGE_FETCH_ATTEMPTS,
    });
    graphApi.getMessage.mockRejectedValue(new Error("still broken"));

    await incrementalSyncBatchFn(host, []);

    // attempts would exceed the cap → key dropped so the drain can't wedge.
    expect(pendingKeysIn(map)).toEqual([]);
  });

  it("does not schedule a continuation when everything fit in one pass", async () => {
    const { host, scheduleIncrementalSyncDrain } = makeHost({
      [`${PENDING_MSG_PREFIX}m1`]: 0,
    });
    graphApi.getMessage.mockResolvedValue(null);

    await incrementalSyncBatchFn(host, []);

    expect(scheduleIncrementalSyncDrain).not.toHaveBeenCalled();
  });
});
