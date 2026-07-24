import { describe, expect, it, vi } from "vitest";

vi.mock("./api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./api")>();
  return { ...actual, createTask: vi.fn() };
});

import { mapTaskStatus, resolveCollaboratorContact, Todoist } from "./todoist";
import * as api from "./api";
import type { TodoistCollaborator } from "./api";

describe("mapTaskStatus", () => {
  it("returns 'done' for completed tasks regardless of section", () => {
    expect(mapTaskStatus({ checked: true, section_id: "123" } as any)).toBe("done");
  });

  it("returns 'done' for a completed task with no section", () => {
    expect(mapTaskStatus({ checked: true, section_id: null } as any)).toBe("done");
  });

  it("returns the section id for an open task in a section", () => {
    expect(mapTaskStatus({ checked: false, section_id: "123" } as any)).toBe("123");
  });

  it("returns 'open' for an open task with no section", () => {
    expect(mapTaskStatus({ checked: false, section_id: null } as any)).toBe("open");
  });

  it("returns 'open' for an open task with undefined section", () => {
    expect(mapTaskStatus({ checked: false } as any)).toBe("open");
  });
});

describe("resolveCollaboratorContact", () => {
  const collaborators: TodoistCollaborator[] = [
    { id: "u1", name: "Ada Lovelace", email: "ada@example.com" },
    { id: "u2", name: "Alan Turing", email: "alan@example.com" },
  ];

  it("resolves a comment author from posted_uid against the collaborator list", () => {
    // A note:added webhook / backfilled comment carries posted_uid; it must
    // resolve to the real poster, not the connector.
    expect(resolveCollaboratorContact(collaborators, "u2")).toEqual({
      name: "Alan Turing",
      email: "alan@example.com",
      source: { accountId: "u2" },
    });
  });

  it("falls back to an account-id contact when the creator is not a collaborator", () => {
    // Personal/non-shared projects omit the creator from the collaborator
    // list; attribute via the account id rather than the connector.
    expect(resolveCollaboratorContact(collaborators, "owner-99")).toEqual({
      name: "",
      source: { accountId: "owner-99" },
    });
  });

  it("returns undefined when no id is present", () => {
    expect(resolveCollaboratorContact(collaborators, null)).toBeUndefined();
    expect(resolveCollaboratorContact(collaborators, undefined)).toBeUndefined();
  });
});

describe("Todoist.onCreateLink — to-do default", () => {
  function fakeThis() {
    return { getToken: async () => "tok" } as unknown as Todoist;
  }

  it("marks the created task as to-do when created open", async () => {
    vi.mocked(api.createTask).mockResolvedValue({
      id: "task-1",
      content: "Buy milk",
      description: "",
      checked: false,
      project_id: "proj-1",
      section_id: null,
      parent_id: null,
      priority: 1,
      due: null,
      url: "https://app.todoist.com/app/task/task-1",
      responsible_uid: null,
      added_by_uid: null,
      added_at: "2026-07-24T00:00:00.000Z",
      labels: [],
    });

    const result = await Todoist.prototype.onCreateLink.call(fakeThis(), {
      type: "task",
      channelId: "proj-1",
      status: "open",
      title: "Buy milk",
      noteContent: null,
      contacts: [],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any);

    expect(result?.todo).toBe(true);
  });

  it("does not mark the created task as to-do when composed as done", async () => {
    vi.mocked(api.createTask).mockResolvedValue({
      id: "task-2",
      content: "Buy milk",
      description: "",
      checked: false,
      project_id: "proj-1",
      section_id: null,
      parent_id: null,
      priority: 1,
      due: null,
      url: "https://app.todoist.com/app/task/task-2",
      responsible_uid: null,
      added_by_uid: null,
      added_at: "2026-07-24T00:00:00.000Z",
      labels: [],
    });

    const result = await Todoist.prototype.onCreateLink.call(fakeThis(), {
      type: "task",
      channelId: "proj-1",
      status: "done",
      title: "Buy milk",
      noteContent: null,
      contacts: [],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any);

    expect(result?.todo).toBeUndefined();
  });
});
