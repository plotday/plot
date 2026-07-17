import { describe, it, expect } from "vitest";

import { mapTaskStatus, resolveCollaboratorContact } from "./todoist";
import type { TodoistCollaborator } from "./api";

describe("mapTaskStatus", () => {
  it("returns 'done' for completed tasks regardless of section", () => {
    expect(mapTaskStatus({ is_completed: true, section_id: "123" } as any)).toBe("done");
  });

  it("returns 'done' for a completed task with no section", () => {
    expect(mapTaskStatus({ is_completed: true, section_id: null } as any)).toBe("done");
  });

  it("returns the section id for an open task in a section", () => {
    expect(mapTaskStatus({ is_completed: false, section_id: "123" } as any)).toBe("123");
  });

  it("returns 'open' for an open task with no section", () => {
    expect(mapTaskStatus({ is_completed: false, section_id: null } as any)).toBe("open");
  });

  it("returns 'open' for an open task with undefined section", () => {
    expect(mapTaskStatus({ is_completed: false } as any)).toBe("open");
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
