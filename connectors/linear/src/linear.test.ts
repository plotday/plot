import { describe, it, expect, vi } from "vitest";

import { Linear } from "./linear";

/**
 * In-memory store backing `this.get` / `this.set` / `this.clear` (which
 * delegate to `this.tools.store`), mirroring the harness used by the other
 * connector tests (see slack.test.ts).
 */
function makeStore(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(Object.entries(initial));
  return {
    map,
    get: vi.fn(async (key: string) => (map.has(key) ? map.get(key) : null)),
    set: vi.fn(async (key: string, value: unknown) => {
      map.set(key, value);
    }),
    clear: vi.fn(async (key: string) => {
      map.delete(key);
    }),
    list: vi.fn(async (prefix: string) =>
      [...map.keys()].filter((k) => k.startsWith(prefix))
    ),
  };
}

/** Fake Linear client returning a single controlled page of issues. */
function fakeClient(page: {
  nodes: unknown[];
  hasNextPage: boolean;
  endCursor: string | null;
}) {
  return {
    client: {
      rawRequest: vi.fn().mockResolvedValue({
        data: {
          team: {
            issues: {
              nodes: page.nodes,
              pageInfo: {
                hasNextPage: page.hasNextPage,
                endCursor: page.endCursor,
              },
            },
          },
        },
      }),
    },
  };
}

function makeLinear(opts: {
  store: ReturnType<typeof makeStore>;
  channelSyncCompleted: ReturnType<typeof vi.fn>;
  tasksRunTask?: ReturnType<typeof vi.fn>;
}): Linear {
  const tools = {
    store: opts.store,
    integrations: {
      get: vi.fn().mockResolvedValue({ token: "tok" }),
      saveLink: vi.fn().mockResolvedValue("thread-1"),
      channelSyncCompleted: opts.channelSyncCompleted,
    },
    tasks: { runTask: opts.tasksRunTask ?? vi.fn() },
    network: {},
  };
  return new Linear("twist-instance-1" as never, {
    getTools: () => tools,
  } as never);
}

describe("syncBatch initial-sync completion signal", () => {
  const pid = "team-1";

  it("signals channelSyncCompleted once the final page is reached", async () => {
    const store = makeStore({
      [`sync_state_${pid}`]: {
        after: null,
        batchNumber: 1,
        issuesProcessed: 0,
        initialSync: true,
      },
      // Seed viewer info so cacheViewerInfo early-returns (no client.viewer).
      [`viewer_info_${pid}`]: { linearId: "v1" },
    });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const linear = makeLinear({ store, channelSyncCompleted });
    (linear as unknown as { getClient: unknown }).getClient = vi
      .fn()
      .mockResolvedValue(
        fakeClient({ nodes: [], hasNextPage: false, endCursor: null })
      );

    await (
      linear as unknown as {
        syncBatch: (p: string, o: unknown) => Promise<void>;
      }
    ).syncBatch(pid, null);

    expect(channelSyncCompleted).toHaveBeenCalledTimes(1);
    expect(channelSyncCompleted).toHaveBeenCalledWith(pid);
    // The sync state is cleaned up once the backfill is done.
    expect(store.map.has(`sync_state_${pid}`)).toBe(false);
  });

  it("does NOT signal completion while more pages remain", async () => {
    const store = makeStore({
      [`sync_state_${pid}`]: {
        after: null,
        batchNumber: 1,
        issuesProcessed: 0,
        initialSync: true,
      },
      [`viewer_info_${pid}`]: { linearId: "v1" },
    });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const tasksRunTask = vi.fn().mockResolvedValue(undefined);
    const linear = makeLinear({ store, channelSyncCompleted, tasksRunTask });
    (linear as unknown as { getClient: unknown }).getClient = vi
      .fn()
      .mockResolvedValue(
        fakeClient({ nodes: [], hasNextPage: true, endCursor: "cursor-2" })
      );
    (linear as unknown as { callback: unknown }).callback = vi
      .fn()
      .mockResolvedValue("cb-token");

    await (
      linear as unknown as {
        syncBatch: (p: string, o: unknown) => Promise<void>;
      }
    ).syncBatch(pid, null);

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    // Next batch is queued and the cursor advanced.
    expect(tasksRunTask).toHaveBeenCalledTimes(1);
    expect(
      (store.map.get(`sync_state_${pid}`) as { after: string }).after
    ).toBe("cursor-2");
  });
});
