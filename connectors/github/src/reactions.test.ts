import { describe, expect, it } from "vitest";
import { commentEndpointForKey, reconcileCommentReactions, pollOpenPRReactions } from "./reactions";

describe("commentEndpointForKey", () => {
  it("routes a comment- key to the issue-comment endpoint", () => {
    expect(commentEndpointForKey("comment-123")).toEqual({
      commentId: "123",
      kind: "issue",
    });
  });

  it("routes a review-comment- key to the review-comment endpoint", () => {
    expect(commentEndpointForKey("review-comment-456")).toEqual({
      commentId: "456",
      kind: "review",
    });
  });

  it("returns null for a description key", () => {
    expect(commentEndpointForKey("description")).toBeNull();
  });

  it("returns null for a review- (summary) key", () => {
    expect(commentEndpointForKey("review-789")).toBeNull();
  });

  it("returns null for a null key", () => {
    expect(commentEndpointForKey(null)).toBeNull();
  });
});

describe("reconcileCommentReactions", () => {
  it("fetches reactions and calls setNoteReactions with the mapped emoji state", async () => {
    const setNoteReactionsCalls: any[] = [];
    const fakeSource = {
      githubFetch: async () => ({
        ok: true,
        json: async () => [
          { id: 1, content: "+1", user: { id: 10, login: "alice" } },
          { id: 2, content: "+1", user: { id: 11, login: "bob" } },
          { id: 3, content: "heart", user: { id: 10, login: "alice" } },
        ],
      }),
      userToContact: (user: { id: number; login: string }) => ({
        email: `${user.id}+${user.login}@users.noreply.github.com`,
        name: user.login,
        source: { accountId: String(user.id) },
      }),
      setNoteReactions: async (...args: any[]) => {
        setNoteReactionsCalls.push(args);
      },
    } as any;

    await reconcileCommentReactions(
      fakeSource,
      "fake-token",
      "acme",
      "repo",
      42,
      "comment-123"
    );

    expect(setNoteReactionsCalls).toHaveLength(1);
    const [thread, key, reactions] = setNoteReactionsCalls[0];
    expect(thread).toEqual({ source: "github:pr:acme/repo/42" });
    expect(key).toBe("comment-123");
    expect(reactions["👍"]).toHaveLength(2);
    expect(reactions["❤️"]).toHaveLength(1);
  });

  it("no-ops for a key with no known GitHub endpoint", async () => {
    const setNoteReactionsCalls: any[] = [];
    const fakeSource = {
      githubFetch: async () => ({ ok: true, json: async () => [] }),
      userToContact: (u: any) => u,
      setNoteReactions: async (...a: any[]) => setNoteReactionsCalls.push(a),
    } as any;

    await reconcileCommentReactions(fakeSource, "fake-token", "acme", "repo", 42, "description");

    expect(setNoteReactionsCalls).toHaveLength(0);
  });
});

describe("pollOpenPRReactions", () => {
  it("reconciles reactions for every tracked comment across every open PR", async () => {
    const reconciled: string[] = [];
    const stored: Record<string, string[]> = {
      "open_pr_comment_keys_acme/repo_42": ["comment-1", "review-comment-2"],
      "open_pr_comment_keys_acme/repo_43": ["comment-3"],
    };
    const fakeSource = {
      listStoreKeys: async (prefix: string) =>
        Object.keys(stored).filter((k) => k.startsWith(prefix)),
      get: async (key: string) => stored[key] ?? null,
      getToken: async () => "fake-token",
      githubFetch: async () => ({ ok: true, json: async () => [] }),
      userToContact: (u: any) => u,
      setNoteReactions: async (_thread: any, key: string) => {
        reconciled.push(key);
      },
    } as any;

    await pollOpenPRReactions(fakeSource);

    expect(reconciled.sort()).toEqual(["comment-1", "comment-3", "review-comment-2"]);
  });

  it("skips a repo whose token is unavailable without throwing", async () => {
    const stored: Record<string, string[]> = {
      "open_pr_comment_keys_acme/repo_42": ["comment-1"],
    };
    const fakeSource = {
      listStoreKeys: async (prefix: string) =>
        Object.keys(stored).filter((k) => k.startsWith(prefix)),
      get: async (key: string) => stored[key] ?? null,
      getToken: async () => {
        throw new Error("no token");
      },
      githubFetch: async () => ({ ok: true, json: async () => [] }),
      userToContact: (u: any) => u,
      setNoteReactions: async () => {
        throw new Error("should not be called");
      },
    } as any;

    await expect(pollOpenPRReactions(fakeSource)).resolves.toBeUndefined();
  });
});
