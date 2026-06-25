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
