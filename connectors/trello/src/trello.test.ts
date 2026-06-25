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

describe("setupWebhook", () => {
  it("skips registration for localhost URLs (dev guard)", async () => {
    const createWebhook = vi.fn().mockResolvedValue("http://localhost:8787/hook/x");
    const store = makeStore();
    const trello = makeTrello({ store, network: { createWebhook } });
    const apiCreate = vi.fn();
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ createWebhook: apiCreate });

    await (trello as unknown as { setupWebhook: (b: string) => Promise<void> }).setupWebhook("b1");
    expect(apiCreate).not.toHaveBeenCalled();
    expect(store.map.has("webhook_id_b1")).toBe(false);
  });

  it("registers the webhook and stores id + callback url for non-localhost", async () => {
    const url = "https://api.plot.test/hook/abc";
    const createWebhook = vi.fn().mockResolvedValue(url);
    const store = makeStore();
    const trello = makeTrello({ store, network: { createWebhook } });
    const apiCreate = vi.fn().mockResolvedValue({ id: "wh1" });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ createWebhook: apiCreate });

    await (trello as unknown as { setupWebhook: (b: string) => Promise<void> }).setupWebhook("b1");
    expect(apiCreate).toHaveBeenCalledWith("b1", url);
    expect(store.map.get("webhook_id_b1")).toBe("wh1");
    expect(store.map.get("webhook_url_b1")).toBe(url);
  });
});

describe("onWebhook", () => {
  const url = "https://api.plot.test/hook/abc";
  const body = JSON.stringify({ action: { type: "updateCard", data: { card: { id: "card9" } } } });

  async function sign(secret: string, raw: string, cb: string) {
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
    const s = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw + cb));
    return btoa(String.fromCharCode(...new Uint8Array(s)));
  }

  it("re-fetches the card and saves it when the signature is valid", async () => {
    const store = makeStore({ webhook_url_b1: url });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const trello = makeTrello({ store, integrations: { saveLink } });
    const getCard = vi.fn().mockResolvedValue({ id: "card9", name: "C", desc: "", idList: "l1", idBoard: "b1", closed: false, url: "u", idMembers: [], dateLastActivity: "2026-01-01T00:00:00Z" });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ getCard });
    const sig = await sign("SEC", body, url);

    await (trello as unknown as { onWebhook: (r: unknown, b: string) => Promise<void> }).onWebhook(
      { method: "POST", headers: { "x-trello-webhook": sig }, params: {}, body: JSON.parse(body), rawBody: body }, "b1",
    );
    expect(getCard).toHaveBeenCalledWith("card9");
    expect(saveLink).toHaveBeenCalledTimes(1);
    expect(saveLink.mock.calls[0][0].source).toBe("trello:card:card9");
  });

  it("ignores a webhook with an invalid signature", async () => {
    const store = makeStore({ webhook_url_b1: url });
    const saveLink = vi.fn();
    const trello = makeTrello({ store, integrations: { saveLink } });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ getCard: vi.fn() });

    await (trello as unknown as { onWebhook: (r: unknown, b: string) => Promise<void> }).onWebhook(
      { method: "POST", headers: { "x-trello-webhook": "bad" }, params: {}, body: JSON.parse(body), rawBody: body }, "b1",
    );
    expect(saveLink).not.toHaveBeenCalled();
  });
});

describe("onLinkUpdated", () => {
  function linkWith(over: Record<string, unknown>) {
    return { meta: { cardId: "c1", boardId: "b1", idList: "l1" }, status: "l2", title: "C", archived: false, ...over } as any;
  }
  it("moves the card to the new list", async () => {
    const trello = makeTrello();
    const updateCard = vi.fn().mockResolvedValue({});
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ updateCard });
    await trello.onLinkUpdated(linkWith({ status: "l3" }));
    expect(updateCard).toHaveBeenCalledWith("c1", expect.objectContaining({ idList: "l3" }));
  });
  it("no-ops when meta.cardId is missing", async () => {
    const trello = makeTrello();
    const updateCard = vi.fn();
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ updateCard });
    await trello.onLinkUpdated({ meta: {}, status: "l2" } as any);
    expect(updateCard).not.toHaveBeenCalled();
  });
});

describe("comment write-back", () => {
  const thread = { meta: { cardId: "c1", boardId: "b1" } } as any;
  it("onNoteCreated posts a comment and returns the keyed baseline", async () => {
    const trello = makeTrello();
    const addComment = vi.fn().mockResolvedValue({ id: "act5", data: { text: "hello" } });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ addComment });
    const res = await trello.onNoteCreated({ content: "hello" } as any, thread);
    expect(addComment).toHaveBeenCalledWith("c1", "hello");
    expect(res).toEqual({ key: "comment-act5", externalContent: "hello" });
  });
  it("onNoteUpdated edits an existing comment", async () => {
    const trello = makeTrello();
    const updateComment = vi.fn().mockResolvedValue({ id: "act5", data: { text: "edited" } });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ updateComment });
    const res = await trello.onNoteUpdated({ key: "comment-act5", content: "edited" } as any, thread);
    expect(updateComment).toHaveBeenCalledWith("act5", "edited");
    expect(res).toEqual({ externalContent: "edited" });
  });
  it("onNoteUpdated maps the description note to the card desc", async () => {
    const trello = makeTrello();
    const updateCard = vi.fn().mockResolvedValue({ desc: "new desc" });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ updateCard });
    const res = await trello.onNoteUpdated({ key: "description", content: "new desc" } as any, thread);
    expect(updateCard).toHaveBeenCalledWith("c1", { desc: "new desc" });
    expect(res).toEqual({ externalContent: "new desc" });
  });
});
