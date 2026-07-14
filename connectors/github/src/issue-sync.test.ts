import { describe, expect, it } from "vitest";
import { convertIssueToLink } from "./issue-sync";
import type { GitHubIssueComment } from "./github";

function makeIssue(overrides: Record<string, unknown> = {}) {
  return {
    number: 42,
    title: "A bug",
    body: "The description.",
    html_url: "https://github.com/acme/web/issues/42",
    created_at: "2026-07-01T00:00:00Z",
    closed_at: null,
    user: { id: 1, login: "octocat" },
    assignees: [],
    assignee: null,
    ...overrides,
  };
}

const comment = (id: number): GitHubIssueComment => ({
  id,
  body: `comment ${id}`,
  created_at: "2026-07-02T00:00:00Z",
  updated_at: "2026-07-02T00:00:00Z",
  user: { id: 9, login: "commenter" },
  html_url: "",
});

/** A page of `n` comments with ids starting at `base`. */
const commentPage = (n: number, base: number) =>
  Array.from({ length: n }, (_, i) => comment(base + i));

/**
 * Fake source serving a preconfigured list of comment pages keyed by the
 * `page=` query param, recording every requested path.
 */
function makeIssueSource(commentPages: GitHubIssueComment[][]): {
  source: any;
  paths: string[];
} {
  const paths: string[] = [];
  const source = {
    userToContact: (user: { id: number; login: string }) => ({
      email: `${user.id}+${user.login}@users.noreply.github.com`,
      name: user.login,
      source: { accountId: String(user.id) },
    }),
    githubFetch: async (_token: string, path: string) => {
      paths.push(path);
      const pageNum = Number(new URLSearchParams(path.split("?")[1]).get("page"));
      const items = commentPages[pageNum - 1] ?? [];
      return { ok: true, json: async () => items } as unknown as Response;
    },
  };
  return { source, paths };
}

const commentNotes = (link: any) =>
  link.notes.filter((n: any) => typeof n.key === "string" && n.key.startsWith("comment-"));

describe("convertIssueToLink comment fetching", () => {
  it("always emits a description note", async () => {
    const { source } = makeIssueSource([[]]);
    const link = await convertIssueToLink(source, "tok", "acme", "web", makeIssue(), "acme/web", false);
    const description = link?.notes?.find((n: any) => n.key === "description");
    expect(description?.content).toBe("The description.");
  });

  it("fetches every comment in a single request when under the page cap", async () => {
    const { source, paths } = makeIssueSource([commentPage(30, 0)]);
    const link = await convertIssueToLink(source, "tok", "acme", "web", makeIssue(), "acme/web", false);
    expect(commentNotes(link)).toHaveLength(30);
    expect(paths).toHaveLength(1);
  });

  it("caps at MAX_COMMENT_PAGES and never issues a request past the cap", async () => {
    const { source, paths } = makeIssueSource([
      commentPage(100, 0),
      commentPage(100, 100),
      commentPage(100, 200),
      commentPage(100, 300),
    ]);
    const link = await convertIssueToLink(source, "tok", "acme", "web", makeIssue(), "acme/web", false);
    // Keeps 3 pages (300 comments), never fetches the 4th full page.
    expect(commentNotes(link)).toHaveLength(300);
    expect(paths).toHaveLength(3);
  });

  it("requests comments newest-first so the retained pages are the most recent", async () => {
    const { source, paths } = makeIssueSource([commentPage(10, 0)]);
    await convertIssueToLink(source, "tok", "acme", "web", makeIssue(), "acme/web", false);
    expect(paths[0]).toContain("/repos/acme/web/issues/42/comments");
    expect(paths[0]).toContain("sort=created");
    expect(paths[0]).toContain("direction=desc");
  });
});
