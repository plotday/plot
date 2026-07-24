import { describe, expect, it } from "vitest";
import type { ImapMessage } from "@plotday/twister/tools/imap";

import { buildAttachmentRef, fetchOriginalAttachments, parseAttachmentRef } from "./attachments";
import type { MailHost } from "./mail-host";

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

/** A MailHost whose `imap.fetchAttachment` returns fixed bytes per partNumber,
 *  or throws for a partNumber in `failing`. Records every selectMailbox call
 *  and every partNumber `fetchAttachment` was actually invoked for. */
function mockAttachmentHost(opts: {
  bytes: Record<string, Uint8Array>;
  failing?: Set<string>;
}): { host: MailHost; selected: string[]; fetchedParts: string[] } {
  const selected: string[] = [];
  const fetchedParts: string[] = [];
  const imap = {
    connect: async () => "session",
    disconnect: async () => {},
    listMailboxes: async () => [],
    selectMailbox: async (_s: string, box: string) => {
      selected.push(box);
      return { name: box, exists: 0, recent: 0, uidValidity: 1, uidNext: 100 };
    },
    search: async () => [],
    fetchMessages: async () => [],
    setFlags: async () => {},
    fetchAttachment: async (_s: string, _uid: number, partNumber: string) => {
      fetchedParts.push(partNumber);
      if (opts.failing?.has(partNumber)) throw new Error(`fetch failed: ${partNumber}`);
      const bytes = opts.bytes[partNumber];
      if (!bytes) throw new Error(`no such part: ${partNumber}`);
      return bytes;
    },
  };
  const host = {
    imap,
    integrations: {} as never,
    smtp: {} as never,
    appleId: "me@icloud.com",
    appPassword: "pw",
    set: async () => {},
    get: async () => undefined,
    clear: async () => {},
    channelSyncCompleted: async () => {},
    queueWritebackDrain: async () => {},
  } as unknown as MailHost;
  return { host, selected, fetchedParts };
}

function attachmentMessage(over: Partial<ImapMessage> = {}): ImapMessage {
  return {
    uid: 42,
    flags: [],
    attachments: [
      { partNumber: "2", fileName: "photo.png", mimeType: "image/png", size: 3, encoding: "base64" },
    ],
    ...over,
  } as unknown as ImapMessage;
}

describe("fetchOriginalAttachments", () => {
  it("returns one {fileName,mimeType,data} entry per attachment part", async () => {
    const data = new Uint8Array([1, 2, 3]);
    const { host, selected } = mockAttachmentHost({ bytes: { "2": data } });
    const out = await fetchOriginalAttachments(host, "session", "INBOX", attachmentMessage());
    expect(selected).toContain("INBOX");
    expect(out).toEqual([{ fileName: "photo.png", mimeType: "image/png", data }]);
  });

  it("skips a part whose fetchAttachment throws and continues with the rest", async () => {
    const data = new Uint8Array([9, 9]);
    const message = attachmentMessage({
      attachments: [
        { partNumber: "2", fileName: "bad.png", mimeType: "image/png", size: 1, encoding: "base64" },
        { partNumber: "3", fileName: "good.png", mimeType: "image/png", size: 2, encoding: "base64" },
      ],
    } as never);
    const { host } = mockAttachmentHost({ bytes: { "3": data }, failing: new Set(["2"]) });
    const out = await fetchOriginalAttachments(host, "session", "INBOX", message);
    expect(out).toEqual([{ fileName: "good.png", mimeType: "image/png", data }]);
  });

  it("returns an empty array when the message has no attachments", async () => {
    const { host } = mockAttachmentHost({ bytes: {} });
    const out = await fetchOriginalAttachments(
      host,
      "session",
      "INBOX",
      attachmentMessage({ attachments: undefined })
    );
    expect(out).toEqual([]);
  });

  it("FIX 6: skips a synthesized-name calendar part ('attachment') without fetching or re-attaching it", async () => {
    const photoData = new Uint8Array([1, 2, 3]);
    const message = attachmentMessage({
      attachments: [
        { partNumber: "2", fileName: "photo.png", mimeType: "image/png", size: 3, encoding: "base64" },
        { partNumber: "3", fileName: "attachment", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    } as never);
    const { host, fetchedParts } = mockAttachmentHost({
      bytes: { "2": photoData, "3": new Uint8Array([9]) },
    });
    const out = await fetchOriginalAttachments(host, "session", "INBOX", message);
    expect(out).toEqual([{ fileName: "photo.png", mimeType: "image/png", data: photoData }]);
    expect(fetchedParts).toEqual(["2"]); // part "3" (the synthesized calendar part) never fetched
  });

  it("FIX 6: keeps a genuinely-named calendar attachment (e.g. invite.ics)", async () => {
    const icsData = new Uint8Array([7, 7]);
    const message = attachmentMessage({
      attachments: [
        { partNumber: "2", fileName: "invite.ics", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    } as never);
    const { host } = mockAttachmentHost({ bytes: { "2": icsData } });
    const out = await fetchOriginalAttachments(host, "session", "INBOX", message);
    expect(out).toEqual([{ fileName: "invite.ics", mimeType: "text/calendar", data: icsData }]);
  });
});
