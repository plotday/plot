import { describe, expect, it } from "vitest";
import { GitHub } from "./github";

/**
 * `onNoteCreated`/`onNoteUpdated` are real methods on the `GitHub` class,
 * but the class itself requires the twist runtime's `build()` machinery to
 * construct (tool wiring, etc.) — not available in a unit test. Since the
 * methods only touch `this.getToken` / `this.githubFetch` (both public,
 * duck-typed helpers) plus the imported pr-sync/issue-sync functions (which
 * themselves only need those same two methods on their `source` param), we
 * can invoke the unbound prototype methods against a plain fake object
 * implementing just `githubFetch` and `getToken`, per the pattern used
 * throughout `pr-sync.test.ts` / `reactions.test.ts`.
 */
function makeFakeSource(handleFetch: (path: string, options: any) => any) {
  return {
    getToken: async () => "fake-token",
    githubFetch: async (_token: string, path: string, options: any) =>
      handleFetch(path, options),
  } as any;
}

describe("onNoteCreated review-comment reply routing", () => {
  it("routes to addReviewCommentReply when reNoteKey is a review-comment key", async () => {
    let capturedPath = "";
    let capturedBody = "";
    const fakeSource = makeFakeSource((path, options) => {
      capturedPath = path;
      capturedBody = options.body;
      return { ok: true, json: async () => ({ id: 999, body: "Good point" }) };
    });

    const thread = {
      meta: { owner: "acme", repo: "repo", prNumber: 42, reNoteKey: "review-comment-555" },
    } as any;
    const note = { content: "Good point" } as any;

    const result = await GitHub.prototype.onNoteCreated.call(fakeSource, note, thread);

    expect(capturedPath).toBe("/repos/acme/repo/pulls/42/comments");
    expect(JSON.parse(capturedBody)).toEqual({ body: "Good point", in_reply_to: 555 });
    expect(result).toEqual({ key: "review-comment-999", externalContent: "Good point" });
  });

  it("falls back to addPRComment when reNoteKey is absent", async () => {
    let capturedPath = "";
    const fakeSource = makeFakeSource((path) => {
      capturedPath = path;
      return { ok: true, json: async () => ({ id: 111, body: "Top-level comment" }) };
    });

    const thread = { meta: { owner: "acme", repo: "repo", prNumber: 42 } } as any;
    const note = { content: "Top-level comment" } as any;

    const result = await GitHub.prototype.onNoteCreated.call(fakeSource, note, thread);

    expect(capturedPath).toBe("/repos/acme/repo/issues/42/comments");
    expect(result).toEqual({ key: "comment-111", externalContent: "Top-level comment" });
  });
});

describe("onNoteUpdated review-comment edit routing", () => {
  it("routes a review-comment- key to the pulls/comments PATCH endpoint", async () => {
    let capturedPath = "";
    let capturedMethod = "";
    const fakeSource = makeFakeSource((path, options) => {
      capturedPath = path;
      capturedMethod = options.method;
      return { ok: true, json: async () => ({ body: "Edited" }) };
    });

    const thread = { meta: { owner: "acme", repo: "repo", prNumber: 42 } } as any;
    const note = { key: "review-comment-555", content: "Edited" } as any;

    const result = await GitHub.prototype.onNoteUpdated.call(fakeSource, note, thread);

    expect(capturedPath).toBe("/repos/acme/repo/pulls/comments/555");
    expect(capturedMethod).toBe("PATCH");
    expect(result).toEqual({ externalContent: "Edited" });
  });

  it("routes a comment- key to the issues/comments PATCH endpoint", async () => {
    let capturedPath = "";
    const fakeSource = makeFakeSource((path) => {
      capturedPath = path;
      return { ok: true, json: async () => ({ body: "Edited" }) };
    });

    const thread = { meta: { owner: "acme", repo: "repo", prNumber: 42 } } as any;
    const note = { key: "comment-777", content: "Edited" } as any;

    const result = await GitHub.prototype.onNoteUpdated.call(fakeSource, note, thread);

    expect(capturedPath).toBe("/repos/acme/repo/issues/comments/777");
    expect(result).toEqual({ externalContent: "Edited" });
  });
});

describe("default-enable everything", () => {
  it("marks every owner channel enabledByDefault: true", async () => {
    const fakeSource = {
      fetchAllRepos: async () => [
        { full_name: "acme/web", owner: { login: "acme" }, name: "web" },
        { full_name: "octo/dotfiles", owner: { login: "octo" }, name: "dotfiles" },
      ],
    } as any;

    const channels = await GitHub.prototype.getChannels.call(
      fakeSource,
      {} as any,
      { token: "fake-token" } as any,
    );

    expect(channels).toHaveLength(2);
    expect(channels.every((c: any) => c.enabledByDefault === true)).toBe(true);
  });
});
