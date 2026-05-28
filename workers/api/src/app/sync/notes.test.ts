import { describe, it, expect } from "vitest";
import { resolveAccessContactsForSend } from "./notes";

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
