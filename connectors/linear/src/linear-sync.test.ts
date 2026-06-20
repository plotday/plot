import { describe, it, expect } from "vitest";

import {
  buildIssueLink,
  resolveAuthorContact,
  type LinearIssueData,
} from "./linear-sync";

const USER = {
  id: "user-1",
  name: "Ada Lovelace",
  email: "ada@example.com",
  avatarUrl: "https://img/ada.png",
};

function issue(overrides: Partial<LinearIssueData> = {}): LinearIssueData {
  return {
    id: "issue-1",
    title: "Fix the thing",
    description: "Steps to repro",
    url: "https://linear.app/team/issue/ABC-1",
    createdAt: "2026-01-02T03:04:05.000Z",
    creator: USER,
    assignee: null,
    state: { id: "state-uuid", type: "started" },
    comments: { nodes: [] },
    attachments: { nodes: [] },
    ...overrides,
  };
}

describe("resolveAuthorContact", () => {
  it("uses provider account id and includes email when present", () => {
    expect(resolveAuthorContact(USER)).toEqual({
      email: "ada@example.com",
      name: "Ada Lovelace",
      avatar: "https://img/ada.png",
      source: { accountId: "user-1" },
    });
  });

  it("falls back to email-only when there is no id", () => {
    expect(
      resolveAuthorContact({ email: "x@y.com", name: "X" })
    ).toEqual({ email: "x@y.com", name: "X", avatar: undefined });
  });

  it("returns undefined for null/undefined user", () => {
    expect(resolveAuthorContact(null)).toBeUndefined();
    expect(resolveAuthorContact(undefined)).toBeUndefined();
  });
});

describe("buildIssueLink", () => {
  it("maps a full issue to a link with notes, actions, author and assignee", () => {
    const link = buildIssueLink(
      issue({
        assignee: { id: "user-2", name: "Bob", email: "bob@x.com", avatarUrl: null },
        comments: {
          nodes: [
            {
              id: "c1",
              body: "first comment",
              createdAt: "2026-01-03T00:00:00.000Z",
              user: { id: "user-3", name: "Cee", email: null, avatarUrl: null },
            },
          ],
        },
        attachments: { nodes: [{ id: "att-1", title: "spec.pdf" }] },
      }),
      "team-9",
      false
    );

    expect(link.source).toBe("linear:issue:issue-1");
    expect(link.type).toBe("issue");
    expect(link.title).toBe("Fix the thing");
    expect(link.created).toEqual(new Date("2026-01-02T03:04:05.000Z"));
    expect(link.status).toBe("state-uuid");
    expect(link.sourceUrl).toBe("https://linear.app/team/issue/ABC-1");
    expect(link.preview).toBe("Steps to repro");
    expect(link.meta).toEqual({ linearId: "issue-1", projectId: "team-9" });

    expect(link.author).toEqual({
      email: "ada@example.com",
      name: "Ada Lovelace",
      avatar: "https://img/ada.png",
      source: { accountId: "user-1" },
    });
    expect(link.assignee).toEqual({
      email: "bob@x.com",
      name: "Bob",
      avatar: undefined,
      source: { accountId: "user-2" },
    });

    // external link action + one fileRef action for the attachment
    expect(link.actions).toEqual([
      { type: "external", title: "Open in Linear", url: "https://linear.app/team/issue/ABC-1" },
      {
        type: "fileRef",
        ref: "att-1",
        fileName: "spec.pdf",
        fileSize: null,
        mimeType: "application/octet-stream",
      },
    ]);

    // description note + one comment note
    expect(link.notes).toHaveLength(2);
    expect(link.notes![0]).toEqual({
      key: "description",
      content: "Steps to repro",
      created: new Date("2026-01-02T03:04:05.000Z"),
      author: {
        email: "ada@example.com",
        name: "Ada Lovelace",
        avatar: "https://img/ada.png",
        source: { accountId: "user-1" },
      },
    });
    expect(link.notes![1]).toEqual({
      key: "comment-c1",
      content: "first comment",
      created: new Date("2026-01-03T00:00:00.000Z"),
      author: { name: "Cee", avatar: undefined, source: { accountId: "user-3" } },
    });
  });

  it("sets unread:false and archived:false only on initial sync", () => {
    const initial = buildIssueLink(issue(), "t", true);
    expect(initial.unread).toBe(false);
    expect(initial.archived).toBe(false);

    const incremental = buildIssueLink(issue(), "t", false);
    expect(incremental).not.toHaveProperty("unread");
    expect(incremental).not.toHaveProperty("archived");
  });

  it("handles a null creator, empty description and missing state", () => {
    const link = buildIssueLink(
      issue({ creator: null, description: "", state: null }),
      "t",
      false
    );
    expect(link.author).toBeUndefined();
    expect(link.assignee).toBeNull();
    // no description content, no preview
    expect(link.preview).toBeNull();
    expect(link.notes![0]).toMatchObject({ key: "description", content: null });
    // status falls back to "unstarted" when there is no workflow state
    expect(link.status).toBe("unstarted");
  });

  it("omits actions entirely when there is no url and no attachments", () => {
    const link = buildIssueLink(
      issue({ url: null, attachments: { nodes: [] } }),
      "t",
      false
    );
    expect(link.actions).toBeUndefined();
  });

  it("emits a comment note with undefined author when the comment user is missing", () => {
    const link = buildIssueLink(
      issue({
        comments: {
          nodes: [
            { id: "c2", body: "anon", createdAt: "2026-01-04T00:00:00.000Z", user: null },
          ],
        },
      }),
      "t",
      false
    );
    expect(link.notes![1]).toEqual({
      key: "comment-c2",
      content: "anon",
      created: new Date("2026-01-04T00:00:00.000Z"),
      author: undefined,
    });
  });
});
