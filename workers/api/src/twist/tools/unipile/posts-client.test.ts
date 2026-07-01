import { describe, expect, test, vi } from "vitest";
import { UnipileClient } from "./client";

const env = { UNIPILE_API_KEY: "k", UNIPILE_WEBHOOK_SECRET: "s" };

function fakeFetch(status: number, body: unknown) {
  return vi.fn(async (_url: string, _init?: RequestInit) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
  );
}

describe("UnipileClient posts (v2)", () => {
  test("createPost posts text to /v2/:acc/posts", async () => {
    const f = fakeFetch(200, { object: "PostCreated", social_id: "urn:li:activity:1" });
    const c = new UnipileClient(env, f as unknown as typeof fetch);
    const res = await c.createPost({ accountId: "acct", text: "hi" });
    expect(res.social_id).toBe("urn:li:activity:1");
    const [url, init] = f.mock.calls[0]!;
    expect(url).toBe("https://api.unipile.com/v2/acct/posts");
    expect(init!.method).toBe("POST");
    expect(JSON.parse(init!.body as string)).toMatchObject({ text: "hi", visibility: "public" });
  });

  test("listComments GETs the post's comments with account_id in the path", async () => {
    const f = fakeFetch(200, { items: [{ id: "c1", text: "yo" }], next_cursor: null });
    const c = new UnipileClient(env, f as unknown as typeof fetch);
    const res = await c.listComments({ accountId: "acct", postId: "urn:li:activity:1", limit: 50 });
    expect(res.items?.[0]?.id).toBe("c1");
    const [url] = f.mock.calls[0]!;
    expect(url).toContain("/v2/acct/posts/urn%3Ali%3Aactivity%3A1/comments");
    expect(url).toContain("limit=50");
  });

  test("createComment includes comment_id when replying", async () => {
    const f = fakeFetch(200, { comment_id: "c2" });
    const c = new UnipileClient(env, f as unknown as typeof fetch);
    await c.createComment({ accountId: "acct", postId: "p", text: "re", commentId: "c1" });
    const [, init] = f.mock.calls[0]!;
    expect(JSON.parse(init!.body as string)).toMatchObject({ text: "re", comment_id: "c1" });
  });

  test("addPostReaction posts reaction_type", async () => {
    const f = fakeFetch(200, {});
    const c = new UnipileClient(env, f as unknown as typeof fetch);
    await c.addPostReaction({ accountId: "acct", socialId: "p", reactionType: "like" });
    const [url, init] = f.mock.calls[0]!;
    expect(url).toContain("/v2/acct/posts/p/reactions");
    expect(JSON.parse(init!.body as string)).toMatchObject({ reaction_type: "like" });
  });
});
