import { afterEach, describe, expect, it, vi } from "vitest";
import { TrelloApi, verifyTrelloWebhook, cardCreatedAt } from "./trello-api";

afterEach(() => vi.restoreAllMocks());

function mockFetchOnce(json: unknown, ok = true, status = 200) {
  return vi.spyOn(globalThis, "fetch").mockResolvedValue(
    new Response(JSON.stringify(json), { status: ok ? status : 400 }),
  );
}

describe("TrelloApi request shaping", () => {
  const api = new TrelloApi("KEY", "TOK");

  it("getBoards calls /members/me/boards with key+token", async () => {
    const f = mockFetchOnce([{ id: "b1", name: "Board" }]);
    const boards = await api.getBoards();
    expect(boards).toEqual([{ id: "b1", name: "Board" }]);
    const url = f.mock.calls[0][0] as string;
    expect(url).toContain("https://api.trello.com/1/members/me/boards");
    expect(url).toContain("key=KEY");
    expect(url).toContain("token=TOK");
    expect(url).toContain("filter=open");
  });

  it("getCards passes limit + before for pagination", async () => {
    const f = mockFetchOnce([]);
    await api.getCards("b1", { limit: 50, before: "card9" });
    const url = f.mock.calls[0][0] as string;
    expect(url).toContain("/boards/b1/cards");
    expect(url).toContain("limit=50");
    expect(url).toContain("before=card9");
    expect(url).toContain("actions=commentCard");
    expect(url).toContain("attachments=true");
    expect(url).toContain("members=true");
  });

  it("addComment POSTs to /cards/{id}/actions/comments and returns the action", async () => {
    const f = mockFetchOnce({ id: "act1", type: "commentCard", date: "2026-01-01T00:00:00Z", data: { text: "hi" } });
    const action = await api.addComment("c1", "hi");
    expect(action.id).toBe("act1");
    const [url, init] = f.mock.calls[0] as [string, RequestInit];
    expect(url).toContain("/cards/c1/actions/comments");
    expect(url).toContain("text=hi");
    expect(init.method).toBe("POST");
  });

  it("createWebhook POSTs idModel + callbackURL", async () => {
    const f = mockFetchOnce({ id: "wh1" });
    const res = await api.createWebhook("b1", "https://api.plot.test/hook/abc");
    expect(res.id).toBe("wh1");
    const [url, init] = f.mock.calls[0] as [string, RequestInit];
    expect(url).toContain("/webhooks");
    expect(init.method).toBe("POST");
    const body = String(init.body);
    expect(body).toContain("idModel=b1");
    expect(body).toContain("callbackURL=");
  });

  it("getCards requests checklists + checkItems with member ids", async () => {
    const f = mockFetchOnce([]);
    await api.getCards("b1", { limit: 50 });
    const url = f.mock.calls[0][0] as string;
    expect(url).toContain("checklists=all");
    expect(url).toContain("checklist_fields=name,pos");
    expect(url).toContain("checkItems=all");
    expect(url).toContain("checkItem_fields=name,state,pos,idMember");
  });

  it("getCard requests checklists + checkItems too", async () => {
    const f = mockFetchOnce({ id: "c1", name: "C" });
    await api.getCard("c1");
    const url = f.mock.calls[0][0] as string;
    expect(url).toContain("checklists=all");
    expect(url).toContain("checkItem_fields=name,state,pos,idMember");
  });
});

describe("cardCreatedAt", () => {
  it("decodes the timestamp from the first 8 hex chars of the id", () => {
    // 0x5f000000 = 1593817600 → 2020-07-03T...; assert it parses to that epoch.
    const d = cardCreatedAt("5f000000aaaaaaaaaaaaaaaa");
    expect(d.getTime()).toBe(0x5f000000 * 1000);
  });
});

describe("verifyTrelloWebhook", () => {
  it("accepts a correct HMAC-SHA1 signature and rejects a wrong one", async () => {
    const secret = "shh";
    const body = '{"action":{"type":"updateCard"}}';
    const callbackURL = "https://api.plot.test/hook/abc";
    // Compute the expected signature with the same primitive the impl uses.
    const key = await crypto.subtle.importKey(
      "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-1" }, false, ["sign"],
    );
    const sigBuf = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body + callbackURL));
    const good = btoa(String.fromCharCode(...new Uint8Array(sigBuf)));
    expect(await verifyTrelloWebhook(secret, body, callbackURL, good)).toBe(true);
    expect(await verifyTrelloWebhook(secret, body, callbackURL, "wrong")).toBe(false);
  });
});
