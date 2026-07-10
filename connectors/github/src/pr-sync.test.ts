import { describe, expect, it } from "vitest";
import { buildPRThreadFields, handlePRWebhook } from "./pr-sync";
import type { GitHubPullRequest } from "./github";

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
