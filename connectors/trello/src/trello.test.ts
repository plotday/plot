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
    const api = { me: vi.fn().mockResolvedValue({ id: "owner1", fullName: "O", username: "o" }), getCards: vi.fn().mockResolvedValue(cards) };
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

describe("checkItem write-back", () => {
  const thread = { meta: { cardId: "c1", boardId: "b1" } } as any;
  function withUpdate(trello: Trello) {
    const updateCheckItem = vi.fn().mockResolvedValue({ id: "ci1", name: "Renamed", state: "complete", pos: 1, idMember: "m1" });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ updateCheckItem });
    return updateCheckItem;
  }

  it("marks complete when a Done actor is present and renames from content", async () => {
    const trello = makeTrello();
    const updateCheckItem = withUpdate(trello);
    const note = { key: "checkitem-ci1", content: "Renamed", tags: { 3: ["a1"] }, tagActors: {} } as any; // Tag.Done = 3
    const res = await trello.onNoteUpdated(note, thread);
    expect(updateCheckItem).toHaveBeenCalledWith("c1", "ci1", expect.objectContaining({ state: "complete", name: "Renamed" }));
    expect(res).toEqual({ externalContent: "Renamed" });
  });

  it("marks incomplete when no Done actor is present", async () => {
    const trello = makeTrello();
    const updateCheckItem = withUpdate(trello);
    const note = { key: "checkitem-ci1", content: "x", tags: {}, tagActors: {} } as any;
    await trello.onNoteUpdated(note, thread);
    expect(updateCheckItem).toHaveBeenCalledWith("c1", "ci1", expect.objectContaining({ state: "incomplete", idMember: "" }));
  });

  it("resolves the assignee to a Trello member via tagActors.source.accountId", async () => {
    const trello = makeTrello();
    const updateCheckItem = withUpdate(trello);
    const note = { key: "checkitem-ci1", content: "x", tags: { 1: ["a1"] }, tagActors: { a1: { id: "a1", source: { accountId: "m1" } } } } as any; // Tag.Todo = 1
    const res = await trello.onNoteUpdated(note, thread);
    expect(updateCheckItem).toHaveBeenCalledWith("c1", "ci1", expect.objectContaining({ idMember: "m1" }));
    expect((res as { deliveryError?: unknown }).deliveryError).toBeUndefined();
  });

  it("returns a deliveryError (without blocking completion) when the assignee has no member id", async () => {
    const trello = makeTrello();
    const updateCheckItem = withUpdate(trello);
    const note = { key: "checkitem-ci1", content: "x", tags: { 1: ["a1"], 3: ["a1"] }, tagActors: { a1: { id: "a1" } } } as any;
    const res = await trello.onNoteUpdated(note, thread);
    const fields = updateCheckItem.mock.calls[0][2];
    expect(fields.idMember).toBeUndefined(); // assignee not written
    expect(fields.state).toBe("complete"); // completion still applied
    expect((res as { deliveryError?: { code: string } }).deliveryError?.code).toBe("invalid_recipient");
  });

  it("ignores non-checkitem keys (falls through to existing handling)", async () => {
    const trello = makeTrello();
    const updateCheckItem = vi.fn();
    const updateCard = vi.fn().mockResolvedValue({ desc: "d" });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ updateCheckItem, updateCard });
    await trello.onNoteUpdated({ key: "description", content: "d" } as any, thread);
    expect(updateCheckItem).not.toHaveBeenCalled();
    expect(updateCard).toHaveBeenCalled();
  });
});

describe("onCreateLink", () => {
  it("creates a card in the chosen list and returns the synced link", async () => {
    const trello = makeTrello();
    const createCard = vi.fn().mockResolvedValue({
      id: "5f000000bbbbbbbbbbbbbbbb", name: "New card", desc: "body", idList: "l1", idBoard: "b1", closed: false, url: "https://trello.com/c/x", idMembers: [], dateLastActivity: "2026-01-01T00:00:00Z",
    });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ createCard });
    const link = await trello.onCreateLink({ channelId: "b1", type: "card", status: "l1", title: "New card", noteContent: "body", contacts: [] } as any);
    expect(createCard).toHaveBeenCalledWith({ idList: "l1", name: "New card", desc: "body" });
    expect(link!.source).toBe("trello:card:5f000000bbbbbbbbbbbbbbbb");
    expect(link!.status).toBe("l1");
    expect(link!.channelId).toBe("b1");
    expect(link!.originatingNote).toEqual({ key: "description", externalContent: "body" });
    expect(link!.meta).toEqual({ syncProvider: "trello", boardId: "b1", cardId: "5f000000bbbbbbbbbbbbbbbb", idList: "l1" });
    expect(link!.type).toBe("card");
  });
  it("returns null for a non-card type", async () => {
    const trello = makeTrello();
    expect(await trello.onCreateLink({ type: "other" } as any)).toBeNull();
  });
});

describe("onChannelDisabled", () => {
  it("deletes the webhook, archives links, and clears state", async () => {
    const store = makeStore({ webhook_id_b1: "wh1", webhook_url_b1: "u", sync_enabled_b1: true });
    const archiveLinks = vi.fn().mockResolvedValue(undefined);
    const trello = makeTrello({ store, integrations: { archiveLinks } });
    const deleteWebhook = vi.fn().mockResolvedValue({});
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ deleteWebhook });

    await trello.onChannelDisabled({ id: "b1", title: "B" } as any);
    expect(deleteWebhook).toHaveBeenCalledWith("wh1");
    expect(archiveLinks).toHaveBeenCalledWith({ channelId: "b1" });
    expect(store.map.has("webhook_id_b1")).toBe(false);
    expect(store.map.has("sync_enabled_b1")).toBe(false);
  });
});

describe("checklist sync wiring", () => {
  const bid = "b1";

  it("fetches+caches the owner member id and passes it to transformCard", async () => {
    const store = makeStore({ [`sync_state_${bid}`]: { before: null, batchNumber: 1, initialSync: true } });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const trello = makeTrello({ store, integrations: { saveLink, channelSyncCompleted: vi.fn().mockResolvedValue(undefined) } });
    const me = vi.fn().mockResolvedValue({ id: "owner1", fullName: "Owner", username: "owner" });
    const getCards = vi.fn().mockResolvedValue([
      { id: "c1", name: "C", desc: "", idList: "l1", idBoard: bid, closed: false, url: "u", idMembers: [], dateLastActivity: "2026-01-01T00:00:00Z",
        checklists: [{ id: "cl1", name: "QA", pos: 1, checkItems: [{ id: "ci1", name: "x", state: "complete", pos: 1, idMember: null }] }] },
    ]);
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ me, getCards });

    await (trello as unknown as { syncBatch: (b: string) => Promise<void> }).syncBatch(bid);

    expect(me).toHaveBeenCalledTimes(1);
    expect(await store.get("me_member_id")).toBe("owner1");
    // owner-attributed Done lands on the saved note
    const savedNotes = saveLink.mock.calls[0][0].notes as Array<{ key: string; tags?: Record<number, Array<{ source?: { accountId?: string } }>> }>;
    const ci1 = savedNotes.find((n) => n.key === "checkitem-ci1")!;
    expect(ci1.tags?.[3]?.[0].source?.accountId).toBe("owner1"); // Tag.Done = 3
    // per-card checklist map persisted for later deletion handling
    expect(await store.get("checklist_items_c1")).toEqual({ cl1: ["ci1"] });
  });

  it("reuses the cached owner id without a second me() call", async () => {
    const store = makeStore({ me_member_id: "ownerX", [`sync_state_${bid}`]: { before: null, batchNumber: 1, initialSync: false } });
    const trello = makeTrello({ store, integrations: { saveLink: vi.fn().mockResolvedValue("t1") } });
    const me = vi.fn();
    const getCards = vi.fn().mockResolvedValue([]);
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ me, getCards });
    await (trello as unknown as { syncBatch: (b: string) => Promise<void> }).syncBatch(bid);
    expect(me).not.toHaveBeenCalled();
  });
});
