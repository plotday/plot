import { describe, expect, it, vi } from "vitest";
import { PostHog } from "./posthog";

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

function makePostHog(
  opts: {
    store?: ReturnType<typeof makeStore>;
    integrations?: Record<string, unknown>;
    options?: Record<string, unknown>;
  } = {}
): PostHog {
  const tools = {
    store: opts.store ?? makeStore(),
    integrations: {
      get: vi.fn().mockResolvedValue({ token: "tok" }),
      saveLink: vi.fn().mockResolvedValue("thread-1"),
      channelSyncCompleted: vi.fn().mockResolvedValue(undefined),
      ...opts.integrations,
    },
    options: { apiKey: "key", projectId: "12345", host: "https://us.posthog.com", ...opts.options },
    tasks: { runTask: vi.fn().mockResolvedValue(undefined) },
  };
  return new PostHog("twist-1" as never, { getTools: () => tools } as never);
}

const channelId = "signup_completed";

function event(uuid: string, distinctId = "person-1") {
  return {
    uuid,
    event: "signup_completed",
    distinct_id: distinctId,
    properties: { plan: "pro" },
    timestamp: "2026-01-01T00:00:00Z",
    person: { properties: { name: "Ada Lovelace" } },
  };
}

describe("syncBatch", () => {
  it("signals channelSyncCompleted when the last page is reached (initial sync)", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: {
        after: null,
        batchNumber: 1,
        eventsProcessed: 0,
        initialSync: true,
      },
    });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const saveLink = vi.fn().mockResolvedValue("t1");
    const posthog = makePostHog({ store, integrations: { channelSyncCompleted, saveLink } });
    const getEvents = vi.fn().mockResolvedValue({ results: [event("e1")] });
    (posthog as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({ getEvents });

    await (
      posthog as unknown as { syncBatch: (id: string, initial?: boolean) => Promise<void> }
    ).syncBatch(channelId, true);

    expect(saveLink).toHaveBeenCalledTimes(1);
    expect(channelSyncCompleted).toHaveBeenCalledWith(channelId);
    // sync state is cleared once the chain has nothing left to schedule
    expect(store.map.has(`sync_state_${channelId}`)).toBe(false);
  });

  it("does not signal channelSyncCompleted while more pages remain", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: {
        after: null,
        batchNumber: 1,
        eventsProcessed: 0,
        initialSync: true,
      },
    });
    const channelSyncCompleted = vi.fn();
    const posthog = makePostHog({ store, integrations: { channelSyncCompleted } });
    const getEvents = vi.fn().mockResolvedValue({ results: [event("e1")], next: "cursor2" });
    (posthog as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({ getEvents });
    (posthog as unknown as { callback: unknown }).callback = vi.fn().mockResolvedValue("cb");

    await (
      posthog as unknown as { syncBatch: (id: string, initial?: boolean) => Promise<void> }
    ).syncBatch(channelId, true);

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    const state = store.map.get(`sync_state_${channelId}`) as { after: string };
    expect(state.after).toBe("cursor2");
  });

  it("does not signal channelSyncCompleted when an incremental (non-initial) sync completes", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: {
        after: null,
        batchNumber: 1,
        eventsProcessed: 0,
        initialSync: false,
      },
    });
    const channelSyncCompleted = vi.fn();
    const saveLink = vi.fn().mockResolvedValue("t1");
    const posthog = makePostHog({ store, integrations: { channelSyncCompleted, saveLink } });
    const getEvents = vi.fn().mockResolvedValue({ results: [event("e1")] });
    (posthog as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({ getEvents });

    await (
      posthog as unknown as { syncBatch: (id: string, initial?: boolean) => Promise<void> }
    ).syncBatch(channelId, false);

    expect(channelSyncCompleted).not.toHaveBeenCalled();
  });

  it("signals channelSyncCompleted on the final page even when it has zero events", async () => {
    const store = makeStore({
      [`sync_state_${channelId}`]: {
        after: null,
        batchNumber: 1,
        eventsProcessed: 0,
        initialSync: true,
      },
    });
    const channelSyncCompleted = vi.fn();
    const posthog = makePostHog({ store, integrations: { channelSyncCompleted } });
    const getEvents = vi.fn().mockResolvedValue({ results: [] });
    (posthog as unknown as { getAPI: unknown }).getAPI = vi.fn().mockReturnValue({ getEvents });

    await (
      posthog as unknown as { syncBatch: (id: string, initial?: boolean) => Promise<void> }
    ).syncBatch(channelId, true);

    expect(channelSyncCompleted).toHaveBeenCalledWith(channelId);
  });
});
