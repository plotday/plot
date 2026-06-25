import { describe, expect, it, vi } from "vitest";
import { Trello } from "./trello";

export function makeStore(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(Object.entries(initial));
  return {
    map,
    get: vi.fn(async (k: string) => (map.has(k) ? map.get(k) : null)),
    set: vi.fn(async (k: string, v: unknown) => void map.set(k, v)),
    clear: vi.fn(async (k: string) => void map.delete(k)),
    list: vi.fn(async (p: string) => [...map.keys()].filter((k) => k.startsWith(p))),
  };
}

export function makeTrello(
  opts: {
    store?: ReturnType<typeof makeStore>;
    integrations?: Record<string, unknown>;
    network?: Record<string, unknown>;
  } = {},
): Trello {
  const tools = {
    store: opts.store ?? makeStore(),
    integrations: {
      get: vi.fn().mockResolvedValue({ token: "tok", provider: { key: "KEY", secret: "SEC" } }),
      saveLink: vi.fn().mockResolvedValue("thread-1"),
      channelSyncCompleted: vi.fn().mockResolvedValue(undefined),
      archiveLinks: vi.fn().mockResolvedValue(undefined),
      ...opts.integrations,
    },
    network: { createWebhook: vi.fn(), deleteWebhook: vi.fn(), ...opts.network },
  };
  return new Trello("twist-1" as never, { getTools: () => tools } as never);
}

describe("getChannels", () => {
  it("returns one channel per board with per-board statuses from lists", async () => {
    const trello = makeTrello();
    const api = {
      getBoards: vi.fn().mockResolvedValue([{ id: "b1", name: "Board One" }]),
      getLists: vi.fn().mockResolvedValue([
        { id: "l1", name: "To Do", pos: 1 },
        { id: "l2", name: "Done", pos: 2 },
      ]),
    };
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue(api);

    const channels = await trello.getChannels();
    expect(channels).toHaveLength(1);
    expect(channels[0].id).toBe("b1");
    expect(channels[0].title).toBe("Board One");
    expect(channels[0].linkTypes![0].statuses).toEqual([
      { status: "l1", label: "To Do", icon: "todo" },
      { status: "l2", label: "Done", icon: "done", done: true },
    ]);
  });
});

describe("syncBatch", () => {
  const bid = "b1";
  function withApi(trello: Trello, cards: unknown[]) {
    const api = { getCards: vi.fn().mockResolvedValue(cards) };
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue(api);
    return api;
  }

  it("saves each card and signals channelSyncCompleted when the last page is reached", async () => {
    const store = makeStore({ [`sync_state_${bid}`]: { before: null, batchNumber: 1, initialSync: true } });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const saveLink = vi.fn().mockResolvedValue("t1");
    const trello = makeTrello({ store, integrations: { channelSyncCompleted, saveLink } });
    withApi(trello, [
      { id: "5f000000aaaaaaaaaaaaaaaa", name: "C1", desc: "", idList: "l1", idBoard: bid, closed: false, url: "u", idMembers: [], dateLastActivity: "2026-01-01T00:00:00Z" },
    ]); // fewer than CARDS_PER_PAGE → last page

    await (trello as unknown as { syncBatch: (b: string) => Promise<void> }).syncBatch(bid);

    expect(saveLink).toHaveBeenCalledTimes(1);
    const saved = saveLink.mock.calls[0][0];
    expect(saved.source).toBe("trello:card:5f000000aaaaaaaaaaaaaaaa");
    expect(saved.unread).toBe(false); // initialSync
    expect(channelSyncCompleted).toHaveBeenCalledWith(bid);
    expect(store.map.has(`sync_state_${bid}`)).toBe(false);
  });

  it("queues the next batch and advances `before` while a full page is returned", async () => {
    const store = makeStore({ [`sync_state_${bid}`]: { before: null, batchNumber: 1, initialSync: true } });
    const channelSyncCompleted = vi.fn();
    const trello = makeTrello({ store, integrations: { channelSyncCompleted } });
    const fullPage = Array.from({ length: 100 }, (_, i) => ({
      id: `5f0000${String(i).padStart(2, "0")}aaaaaaaaaaaaaaaa`.slice(0, 24),
      name: `C${i}`, desc: "", idList: "l1", idBoard: bid, closed: false, url: "u", idMembers: [], dateLastActivity: "2026-01-01T00:00:00Z",
    }));
    withApi(trello, fullPage);
    (trello as unknown as { callback: unknown }).callback = vi.fn().mockResolvedValue("cb");
    (trello as unknown as { runTask: unknown }).runTask = vi.fn().mockResolvedValue(undefined);

    await (trello as unknown as { syncBatch: (b: string) => Promise<void> }).syncBatch(bid);

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    expect((trello as unknown as { runTask: ReturnType<typeof vi.fn> }).runTask).toHaveBeenCalledTimes(1);
    const state = store.map.get(`sync_state_${bid}`) as { before: string };
    expect(state.before).toBe(fullPage[fullPage.length - 1].id); // paginate before the last card
  });
});
