import { describe, it, expect } from "vitest";
import { resolveAccessContactsForSend, resolveAccessGroupsForSend } from "./notes";

describe("resolveAccessContactsForSend", () => {
  it("returns body.access_contacts unchanged when sharing model is thread", () => {
    expect(
      resolveAccessContactsForSend({
        bodyAccessContacts: null,
        sharingModel: "thread",
        threadContacts: ["c1", "c2"],
      }),
    ).toBeNull();
  });

  it("returns body.access_contacts unchanged when sharing model is channel", () => {
    expect(
      resolveAccessContactsForSend({
        bodyAccessContacts: null,
        sharingModel: "channel",
        threadContacts: ["c1", "c2"],
      }),
    ).toBeNull();
  });

  it("falls back to thread.contacts when body is null in message-mode", () => {
    expect(
      resolveAccessContactsForSend({
        bodyAccessContacts: null,
        sharingModel: "message",
        threadContacts: ["c1", "c2"],
      }),
    ).toEqual(["c1", "c2"]);
  });

  it("preserves explicit body.access_contacts in message-mode", () => {
    expect(
      resolveAccessContactsForSend({
        bodyAccessContacts: ["c1"],
        sharingModel: "message",
        threadContacts: ["c1", "c2"],
      }),
    ).toEqual(["c1"]);
  });

  it("preserves an explicit empty array (author-only) in message-mode", () => {
    expect(
      resolveAccessContactsForSend({
        bodyAccessContacts: [],
        sharingModel: "message",
        threadContacts: ["c1", "c2"],
      }),
    ).toEqual([]);
  });
});

describe("resolveAccessGroupsForSend", () => {
  it("returns null when body has no access_groups", () => {
    expect(resolveAccessGroupsForSend({ bodyAccessGroups: null })).toBeNull();
  });

  it("returns null when body access_groups is undefined", () => {
    expect(resolveAccessGroupsForSend({ bodyAccessGroups: undefined })).toBeNull();
  });

  it("returns null when body access_groups is a non-array value", () => {
    expect(resolveAccessGroupsForSend({ bodyAccessGroups: "g1" })).toBeNull();
  });

  it("returns the array when body provides access_groups", () => {
    expect(
      resolveAccessGroupsForSend({ bodyAccessGroups: ["g1", "g2"] }),
    ).toEqual(["g1", "g2"]);
  });

  it("returns an explicit empty array unchanged (no group restriction)", () => {
    expect(resolveAccessGroupsForSend({ bodyAccessGroups: [] })).toEqual([]);
  });

  it("does not apply a message-mode invariant (groups are always pass-through)", () => {
    // Groups have no 'never-null-in-message-mode' rule; null stays null
    // regardless of sharing model. This test documents that contract explicitly.
    expect(resolveAccessGroupsForSend({ bodyAccessGroups: null })).toBeNull();
    expect(resolveAccessGroupsForSend({ bodyAccessGroups: ["g1"] })).toEqual(["g1"]);
  });
});
