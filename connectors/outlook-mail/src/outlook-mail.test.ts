import { describe, expect, it } from "vitest";
import { pickChannelForConversation, recipientsFor } from "./outlook-mail";
import type { GraphMessage, WellKnownFolders } from "./graph-mail-api";

const inFolder = (parentFolderId: string): GraphMessage =>
  ({ id: `m-${parentFolderId}`, parentFolderId }) as GraphMessage;
const wk: WellKnownFolders = {
  inbox: "f-inbox",
  sentitems: "f-sent",
  archive: "f-arch",
};

describe("pickChannelForConversation", () => {
  it("prefers enabled custom folders over inbox", () => {
    expect(
      pickChannelForConversation(
        [inFolder("f-custom"), inFolder("f-inbox")],
        new Set(["f-inbox", "f-custom"]),
        wk
      )
    ).toBe("f-custom");
  });
  it("falls back inbox → sentitems", () => {
    expect(
      pickChannelForConversation(
        [inFolder("f-sent")],
        new Set(["f-inbox", "f-sent"]),
        wk
      )
    ).toBe("f-sent");
    expect(
      pickChannelForConversation(
        [inFolder("f-inbox"), inFolder("f-sent")],
        new Set(["f-inbox", "f-sent"]),
        wk
      )
    ).toBe("f-inbox");
  });
  it("returns null when nothing matches", () => {
    expect(
      pickChannelForConversation([inFolder("f-other")], new Set(["f-inbox"]), wk)
    ).toBeNull();
  });
});

describe("recipientsFor", () => {
  it("excludes self always", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: ["a@b.com", "me@b.com"],
        self: "ME@b.com",
      })
    ).toEqual(["a@b.com"]);
  });
  it("empty constraint set sends to nobody (private note)", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set(),
        candidates: ["a@b.com"],
        self: "me@b.com",
      })
    ).toEqual([]);
  });
  it("constraint filters to allowed", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set(["a@b.com"]),
        candidates: ["a@b.com", "c@d.com"],
        self: "me@b.com",
      })
    ).toEqual(["a@b.com"]);
  });
});
