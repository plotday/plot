import { describe, expect, it } from "vitest";

import { buildAttachmentRef, parseAttachmentRef } from "./attachments";

describe("buildAttachmentRef / parseAttachmentRef", () => {
  it("round-trips mailbox, uid, and partNumber", () => {
    const ref = buildAttachmentRef("INBOX", 42, "2");
    expect(ref).toBe("INBOX:42:2");
    expect(parseAttachmentRef(ref)).toEqual({
      mailbox: "INBOX",
      uid: 42,
      partNumber: "2",
    });
  });

  it("round-trips a nested IMAP part number (e.g. 2.1)", () => {
    const ref = buildAttachmentRef("Sent Messages", 7, "2.1");
    expect(parseAttachmentRef(ref)).toEqual({
      mailbox: "Sent Messages",
      uid: 7,
      partNumber: "2.1",
    });
  });

  it("URI-encodes a mailbox name containing a colon so the split can't be corrupted", () => {
    const ref = buildAttachmentRef("Work:Projects", 3, "2");
    expect(ref).toBe("Work%3AProjects:3:2");
    expect(parseAttachmentRef(ref).mailbox).toBe("Work:Projects");
  });

  it("throws on a malformed ref (wrong segment count)", () => {
    expect(() => parseAttachmentRef("INBOX:42")).toThrow(/Invalid Apple Mail attachment ref/);
    expect(() => parseAttachmentRef("a:b:c:d")).toThrow(/Invalid Apple Mail attachment ref/);
  });

  it("throws on a non-numeric or non-positive uid", () => {
    expect(() => parseAttachmentRef("INBOX:notanumber:2")).toThrow(
      /Invalid Apple Mail attachment ref/
    );
    expect(() => parseAttachmentRef("INBOX:0:2")).toThrow(/Invalid Apple Mail attachment ref/);
  });

  it("throws on an empty part number", () => {
    expect(() => parseAttachmentRef("INBOX:42:")).toThrow(/Invalid Apple Mail attachment ref/);
  });
});
