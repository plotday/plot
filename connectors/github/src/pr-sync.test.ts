import { describe, expect, it } from "vitest";
import {
  addReviewCommentReply,
  buildPRThreadFields,
  buildReviewCommentNote,
  handlePRWebhook,
  handlePRReviewCommentWebhook,
} from "./pr-sync";
import type { GitHubPullRequest, GitHubReviewComment } from "./github";

function makePR(overrides: Partial<GitHubPullRequest> = {}): GitHubPullRequest {
  return {
    id: 1,
    number: 42,
    title: "Add feature",
    body: "This does the thing.",
    state: "open",
    html_url: "https://github.com/acme/repo/pull/42",
    created_at: "2026-07-01T00:00:00Z",
    updated_at: "2026-07-01T00:00:00Z",
    closed_at: null,
    merged_at: null,
    user: { id: 1, login: "octocat" },
    assignee: null,
    draft: false,
    base: { repo: { full_name: "acme/repo", owner: { login: "acme" }, name: "repo" } },
    ...overrides,
  };
}

const fakeSource = {
  userToContact: (user: { id: number; login: string }) => ({
    email: `${user.id}+${user.login}@users.noreply.github.com`,
    name: user.login,
    source: { accountId: String(user.id) },
  }),
} as any;

describe("buildPRThreadFields", () => {
  it("sets sourceUrl to the PR's html_url", () => {
    const fields = buildPRThreadFields(fakeSource, makePR());
    expect(fields.sourceUrl).toBe("https://github.com/acme/repo/pull/42");
  });

  it("includes an Open in GitHub action pointing at html_url", () => {
    const fields = buildPRThreadFields(fakeSource, makePR());
    expect(fields.actions).toEqual([
      { type: "external", title: "Open in GitHub", url: "https://github.com/acme/repo/pull/42" },
    ]);
  });

  it("builds a description note with the PR body", () => {
    const fields = buildPRThreadFields(fakeSource, makePR({ body: "Fixes the bug." }));
    expect(fields.descriptionNote.key).toBe("description");
    expect(fields.descriptionNote.content).toBe("Fixes the bug.");
  });

  it("sets description content to null for an empty/whitespace body", () => {
    const fields = buildPRThreadFields(fakeSource, makePR({ body: "   " }));
    expect(fields.descriptionNote.content).toBeNull();
  });

  it("sets description content to null for a null body", () => {
    const fields = buildPRThreadFields(fakeSource, makePR({ body: null }));
    expect(fields.descriptionNote.content).toBeNull();
  });
});

describe("handlePRWebhook field parity", () => {
  it("sets sourceUrl and actions on an opened PR from a webhook-only sync", async () => {
    const savedLinks: any[] = [];
    const stored: Record<string, any> = {};
    const fakeSource = {
      userToContact: (user: { id: number; login: string }) => ({
        email: `${user.id}+${user.login}@users.noreply.github.com`,
        name: user.login,
        source: { accountId: String(user.id) },
      }),
      saveLink: async (link: any) => {
        savedLinks.push(link);
      },
      getToken: async () => "fake-token",
      githubFetch: async () => ({ ok: true, json: async () => [] }),
      get: async (key: string) => stored[key] ?? null,
      set: async (key: string, value: any) => {
        stored[key] = value;
      },
    } as any;

    await handlePRWebhook(
      fakeSource,
      { action: "opened", pull_request: makePR() },
      "acme/repo",
    );

    expect(savedLinks).toHaveLength(1);
    expect(savedLinks[0].sourceUrl).toBe("https://github.com/acme/repo/pull/42");
    expect(savedLinks[0].actions).toEqual([
      { type: "external", title: "Open in GitHub", url: "https://github.com/acme/repo/pull/42" },
    ]);
    expect(savedLinks[0].notes).toEqual([
      expect.objectContaining({ key: "description", content: "This does the thing." }),
    ]);
  });

  it("omits the description note on a synchronize action", async () => {
    const savedLinks: any[] = [];
    const fakeSource = {
      userToContact: (user: { id: number; login: string }) => ({
        email: `${user.id}+${user.login}@users.noreply.github.com`,
        name: user.login,
        source: { accountId: String(user.id) },
      }),
      saveLink: async (link: any) => {
        savedLinks.push(link);
      },
    } as any;

    await handlePRWebhook(
      fakeSource,
      { action: "synchronize", pull_request: makePR() },
      "acme/repo",
    );

    expect(savedLinks[0].notes).toEqual([]);
    expect(savedLinks[0].sourceUrl).toBe("https://github.com/acme/repo/pull/42");
  });
});

function makeReviewComment(
  overrides: Partial<GitHubReviewComment> = {}
): GitHubReviewComment {
  return {
    id: 555,
    body: "Should this be async?",
    created_at: "2026-07-01T00:00:00Z",
    updated_at: "2026-07-01T00:00:00Z",
    user: { id: 2, login: "reviewer" },
    html_url: "https://github.com/acme/repo/pull/42#discussion_r555",
    path: "src/foo.ts",
    line: 42,
    pull_request_review_id: 1,
    ...overrides,
  };
}

describe("buildReviewCommentNote", () => {
  it("keys the note with the review-comment- prefix", () => {
    const note = buildReviewCommentNote(fakeSource, makeReviewComment());
    expect(note.key).toBe("review-comment-555");
  });

  it("prefixes content with a file/line header", () => {
    const note = buildReviewCommentNote(fakeSource, makeReviewComment());
    expect(note.content).toBe("📄 src/foo.ts:42\n\nShould this be async?");
  });

  it("omits the line number from the header when line is null", () => {
    const note = buildReviewCommentNote(fakeSource, makeReviewComment({ line: null }));
    expect(note.content).toBe("📄 src/foo.ts\n\nShould this be async?");
  });

  it("sets reNote by key when the comment is a reply", () => {
    const note = buildReviewCommentNote(
      fakeSource,
      makeReviewComment({ in_reply_to_id: 111 })
    );
    expect(note.reNote).toEqual({ key: "review-comment-111" });
  });

  it("omits reNote when the comment is not a reply", () => {
    const note = buildReviewCommentNote(fakeSource, makeReviewComment());
    expect(note.reNote).toBeUndefined();
  });
});

describe("handlePRReviewCommentWebhook", () => {
  it("saves a note with the review-comment- key and file/line header", async () => {
    const savedLinks: any[] = [];
    const stored: Record<string, any> = {};
    const fakeSource = {
      userToContact: (user: { id: number; login: string }) => ({
        email: `${user.id}+${user.login}@users.noreply.github.com`,
        name: user.login,
        source: { accountId: String(user.id) },
      }),
      saveLink: async (link: any) => {
        savedLinks.push(link);
      },
      get: async (key: string) => stored[key] ?? null,
      set: async (key: string, value: any) => {
        stored[key] = value;
      },
    } as any;

    await handlePRReviewCommentWebhook(
      fakeSource,
      { action: "created", comment: makeReviewComment(), pull_request: makePR() },
      "acme/repo"
    );

    expect(savedLinks).toHaveLength(1);
    expect(savedLinks[0].notes[0].key).toBe("review-comment-555");
    expect(savedLinks[0].notes[0].content).toContain("📄 src/foo.ts:42");
  });

  it("sets sourceUrl and actions from the PR, matching handlePRWebhook/handleReviewWebhook parity", async () => {
    const savedLinks: any[] = [];
    const stored: Record<string, any> = {};
    const fakeSource = {
      userToContact: (user: { id: number; login: string }) => ({
        email: `${user.id}+${user.login}@users.noreply.github.com`,
        name: user.login,
        source: { accountId: String(user.id) },
      }),
      saveLink: async (link: any) => {
        savedLinks.push(link);
      },
      get: async (key: string) => stored[key] ?? null,
      set: async (key: string, value: any) => {
        stored[key] = value;
      },
    } as any;

    await handlePRReviewCommentWebhook(
      fakeSource,
      { action: "created", comment: makeReviewComment(), pull_request: makePR() },
      "acme/repo"
    );

    expect(savedLinks).toHaveLength(1);
    expect(savedLinks[0].sourceUrl).toBe("https://github.com/acme/repo/pull/42");
    expect(savedLinks[0].actions).toEqual([
      { type: "external", title: "Open in GitHub", url: "https://github.com/acme/repo/pull/42" },
    ]);
  });

  it("appends the new key to open-PR comment-key state", async () => {
    // Storage key format is `open_pr_comment_keys_<repositoryId>_<prNumber>`,
    // and repositoryId ("acme/repo") already contains a slash — so the real
    // key interpolates to "open_pr_comment_keys_acme/repo_42", not
    // "open_pr_comment_keys_acme_repo_42". Seed the fake store with that
    // exact key so appendOpenPRCommentKey's existing-state lookup hits.
    const stored: Record<string, any> = {
      "open_pr_comment_keys_acme/repo_42": ["comment-1"],
    };
    const fakeSource = {
      userToContact: (user: { id: number; login: string }) => ({
        email: `${user.id}+${user.login}@users.noreply.github.com`,
        name: user.login,
        source: { accountId: String(user.id) },
      }),
      saveLink: async () => {},
      get: async (key: string) => stored[key] ?? null,
      set: async (key: string, value: any) => {
        stored[key] = value;
      },
    } as any;

    await handlePRReviewCommentWebhook(
      fakeSource,
      { action: "created", comment: makeReviewComment(), pull_request: makePR() },
      "acme/repo"
    );

    expect(stored["open_pr_comment_keys_acme/repo_42"]).toEqual([
      "comment-1",
      "review-comment-555",
    ]);
  });
});

describe("addReviewCommentReply", () => {
  it("POSTs to the pulls/comments endpoint with in_reply_to", async () => {
    let capturedPath = "";
    let capturedBody = "";
    const fakeSource = {
      githubFetch: async (_token: string, path: string, options: any) => {
        capturedPath = path;
        capturedBody = options.body;
        return {
          ok: true,
          json: async () => ({ id: 999, body: "Good point" }),
        };
      },
      getToken: async () => "fake-token",
    } as any;

    const result = await addReviewCommentReply(
      fakeSource,
      { owner: "acme", repo: "repo", prNumber: 42 },
      555,
      "Good point"
    );

    expect(capturedPath).toBe("/repos/acme/repo/pulls/42/comments");
    expect(JSON.parse(capturedBody)).toEqual({ body: "Good point", in_reply_to: 555 });
    expect(result).toEqual({ id: 999, body: "Good point" });
  });
});
