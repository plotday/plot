import { describe, expect, it } from "vitest";
import {
  addReviewCommentReply,
  buildPRThreadFields,
  buildReviewCommentNote,
  convertPRToThread,
  handlePRWebhook,
  handlePRReviewCommentWebhook,
} from "./pr-sync";
import type {
  GitHubIssueComment,
  GitHubPullRequest,
  GitHubReview,
  GitHubReviewComment,
} from "./github";

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

const convComment = (id: number): GitHubIssueComment => ({
  id,
  body: `conversation ${id}`,
  created_at: "2026-07-02T00:00:00Z",
  updated_at: "2026-07-02T00:00:00Z",
  user: { id: 9, login: "commenter" },
  html_url: "",
});

const reviewItem = (id: number): GitHubReview => ({
  id,
  body: `review ${id}`,
  state: "COMMENTED",
  submitted_at: "2026-07-02T00:00:00Z",
  user: { id: 8, login: "reviewer" },
  html_url: "",
});

const reviewComment = (id: number): GitHubReviewComment => ({
  id,
  body: `inline ${id}`,
  created_at: "2026-07-02T00:00:00Z",
  updated_at: "2026-07-02T00:00:00Z",
  user: { id: 7, login: "inline-reviewer" },
  html_url: "",
  path: "src/a.ts",
  line: 1,
  pull_request_review_id: 1,
});

/** A page of `n` items produced by `build`, with ids starting at `base`. */
const pageOf = <T>(build: (id: number) => T, n: number, base: number): T[] =>
  Array.from({ length: n }, (_, i) => build(base + i));

/**
 * Fake source serving preconfigured pages for the three PR list endpoints,
 * keyed by the `page=` query param and disambiguated by path. Records every
 * requested path so tests can assert per-endpoint request counts and ordering.
 */
function makePRSource(opts: {
  conversation?: GitHubIssueComment[][];
  reviews?: GitHubReview[][];
  reviewComments?: GitHubReviewComment[][];
}): { source: any; paths: string[] } {
  const paths: string[] = [];
  const stored: Record<string, any> = {};
  const source = {
    userToContact: (user: { id: number; login: string }) => ({
      email: `${user.id}+${user.login}@users.noreply.github.com`,
      name: user.login,
      source: { accountId: String(user.id) },
    }),
    githubFetch: async (_token: string, path: string) => {
      paths.push(path);
      const pageNum = Number(new URLSearchParams(path.split("?")[1]).get("page")) || 1;
      let items: unknown[] = [];
      if (path.includes("/reviews")) {
        items = opts.reviews?.[pageNum - 1] ?? [];
      } else if (path.includes("/pulls/") && path.includes("/comments")) {
        items = opts.reviewComments?.[pageNum - 1] ?? [];
      } else if (path.includes("/issues/") && path.includes("/comments")) {
        items = opts.conversation?.[pageNum - 1] ?? [];
      }
      return { ok: true, json: async () => items } as unknown as Response;
    },
    get: async (key: string) => stored[key] ?? null,
    set: async (key: string, value: any) => {
      stored[key] = value;
    },
    clear: async (key: string) => {
      delete stored[key];
    },
  };
  return { source, paths };
}

const notesWithPrefix = (thread: any, prefix: string) =>
  thread.notes.filter((n: any) => typeof n.key === "string" && n.key.startsWith(prefix));
const conversationNotes = (thread: any) =>
  notesWithPrefix(thread, "comment-");
const reviewNotes = (thread: any) =>
  thread.notes.filter(
    (n: any) =>
      typeof n.key === "string" &&
      n.key.startsWith("review-") &&
      !n.key.startsWith("review-comment-"),
  );
const reviewCommentNotes = (thread: any) => notesWithPrefix(thread, "review-comment-");

const convPaths = (paths: string[]) =>
  paths.filter((p) => p.includes("/issues/") && p.includes("/comments"));
const reviewPaths = (paths: string[]) => paths.filter((p) => p.includes("/reviews"));
const reviewCommentPaths = (paths: string[]) =>
  paths.filter((p) => p.includes("/pulls/") && p.includes("/comments"));

describe("convertPRToThread comment fetching", () => {
  it("fetches each list once for a small PR and keeps all content", async () => {
    const { source, paths } = makePRSource({
      conversation: [pageOf(convComment, 3, 0)],
      reviews: [pageOf(reviewItem, 2, 0)],
      reviewComments: [pageOf(reviewComment, 4, 0)],
    });
    const thread = await convertPRToThread(source, "tok", "acme", "repo", makePR(), "acme/repo", false);
    expect(conversationNotes(thread)).toHaveLength(3);
    expect(reviewNotes(thread)).toHaveLength(2);
    expect(reviewCommentNotes(thread)).toHaveLength(4);
    expect(convPaths(paths)).toHaveLength(1);
    expect(reviewPaths(paths)).toHaveLength(1);
    expect(reviewCommentPaths(paths)).toHaveLength(1);
  });

  it("paginates conversation comments newest-first, capped at MAX_COMMENT_PAGES", async () => {
    const { source, paths } = makePRSource({
      conversation: [
        pageOf(convComment, 100, 0),
        pageOf(convComment, 100, 100),
        pageOf(convComment, 100, 200),
        pageOf(convComment, 100, 300),
      ],
    });
    const thread = await convertPRToThread(source, "tok", "acme", "repo", makePR(), "acme/repo", false);
    // No longer silently truncated at 100; capped at 3 pages (300).
    expect(conversationNotes(thread)).toHaveLength(300);
    expect(convPaths(paths)).toHaveLength(3);
    expect(convPaths(paths)[0]).toContain("sort=created");
    expect(convPaths(paths)[0]).toContain("direction=desc");
  });

  it("paginates inline review comments newest-first, capped at MAX_COMMENT_PAGES", async () => {
    const { source, paths } = makePRSource({
      reviewComments: [
        pageOf(reviewComment, 100, 0),
        pageOf(reviewComment, 100, 100),
        pageOf(reviewComment, 100, 200),
        pageOf(reviewComment, 100, 300),
      ],
    });
    const thread = await convertPRToThread(source, "tok", "acme", "repo", makePR(), "acme/repo", false);
    expect(reviewCommentNotes(thread)).toHaveLength(300);
    expect(reviewCommentPaths(paths)).toHaveLength(3);
    expect(reviewCommentPaths(paths)[0]).toContain("sort=created");
    expect(reviewCommentPaths(paths)[0]).toContain("direction=desc");
  });

  it("paginates reviews capped at MAX_COMMENT_PAGES, without a sort direction (endpoint has none)", async () => {
    const { source, paths } = makePRSource({
      reviews: [
        pageOf(reviewItem, 100, 0),
        pageOf(reviewItem, 100, 100),
        pageOf(reviewItem, 100, 200),
        pageOf(reviewItem, 100, 300),
      ],
    });
    const thread = await convertPRToThread(source, "tok", "acme", "repo", makePR(), "acme/repo", false);
    expect(reviewNotes(thread)).toHaveLength(300);
    expect(reviewPaths(paths)).toHaveLength(3);
    // The /pulls/{n}/reviews endpoint takes no sort/direction — fetched in
    // GitHub's default order, not reversed.
    expect(reviewPaths(paths)[0]).not.toContain("direction=desc");
  });
});

describe("handlePRWebhook reopened key refresh", () => {
  it("records conversation-comment keys paginated newest-first (not truncated at 100)", async () => {
    const stored: Record<string, any> = {};
    const paths: string[] = [];
    const source = {
      userToContact: (user: { id: number; login: string }) => ({
        email: `${user.id}+${user.login}@users.noreply.github.com`,
        name: user.login,
        source: { accountId: String(user.id) },
      }),
      saveLink: async () => {},
      getToken: async () => "tok",
      githubFetch: async (_token: string, path: string) => {
        paths.push(path);
        const pageNum = Number(new URLSearchParams(path.split("?")[1]).get("page")) || 1;
        if (path.includes("/issues/") && path.includes("/comments")) {
          // 150 conversation comments across two pages, then a short page.
          const items =
            pageNum === 1
              ? pageOf(convComment, 100, 0)
              : pageNum === 2
                ? pageOf(convComment, 50, 100)
                : [];
          return { ok: true, json: async () => items } as unknown as Response;
        }
        // Review comments: empty.
        return { ok: true, json: async () => [] } as unknown as Response;
      },
      get: async (key: string) => stored[key] ?? null,
      set: async (key: string, value: any) => {
        stored[key] = value;
      },
      clear: async (key: string) => {
        delete stored[key];
      },
    } as any;

    await handlePRWebhook(source, { action: "reopened", pull_request: makePR() }, "acme/repo");

    const keys = stored["open_pr_comment_keys_acme/repo_42"] as string[];
    expect(keys.filter((k) => k.startsWith("comment-"))).toHaveLength(150);
    const convFetches = paths.filter((p) => p.includes("/issues/") && p.includes("/comments"));
    expect(convFetches).toHaveLength(2); // stopped on the short second page
    expect(convFetches[0]).toContain("direction=desc");
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
