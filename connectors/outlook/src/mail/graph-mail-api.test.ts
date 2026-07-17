import { describe, expect, it } from "vitest";
import {
  classifyOutlookCalendar,
  conversationSource,
  GraphMailApi,
  isConversationFlagged,
  isConversationUnread,
  isViaRewrittenName,
  odataQuote,
  recipientEmails,
  sortConversation,
  transformOutlookConversation,
  type GraphAttachmentMeta,
  type GraphHeader,
  type GraphMessage,
} from "./graph-mail-api";

const msg = (over: Partial<GraphMessage>): GraphMessage => ({
  id: "id-1",
  conversationId: "conv-1",
  internetMessageId: "<m1@x>",
  subject: "Hello",
  bodyPreview: "preview",
  body: { contentType: "html", content: "<p>Hi</p>" },
  from: { emailAddress: { name: "Ann", address: "ann@x.com" } },
  toRecipients: [{ emailAddress: { name: "Bob", address: "bob@y.com" } }],
  ccRecipients: [],
  receivedDateTime: "2026-06-01T10:00:00Z",
  isRead: true,
  isDraft: false,
  flag: { flagStatus: "notFlagged" },
  parentFolderId: "f-inbox",
  hasAttachments: false,
  webLink: "https://outlook.office.com/owa/x",
  ...over,
});

describe("transformOutlookConversation", () => {
  const base = {
    attachmentsByMessageId: new Map<string, GraphAttachmentMeta[]>(),
    accountEmail: "Me@Work.com",
  };

  it("maps a two-message conversation to one link with imid-keyed notes", () => {
    const link = transformOutlookConversation({
      ...base,
      messages: [
        msg({}),
        msg({
          id: "id-2",
          internetMessageId: "<m2@x>",
          receivedDateTime: "2026-06-01T11:00:00Z",
          from: { emailAddress: { name: "Bob", address: "bob@y.com" } },
        }),
      ],
    });
    expect(link.source).toBe("outlook-mail:me@work.com:conv-1");
    expect(link.title).toBe("Hello");
    expect(link.notes).toHaveLength(2);
    expect((link.notes![0] as { key: string }).key).toBe("<m1@x>");
    expect((link.notes![1] as { key: string }).key).toBe("<m2@x>");
    expect((link.notes![0] as { contentType: string }).contentType).toBe("html");
    const emails = (link.accessContacts as Array<{ email: string }>)
      .map((c) => c.email)
      .sort();
    expect(emails).toEqual(["ann@x.com", "bob@y.com"]);
    // The thread link is authored by the originating (first) message's sender,
    // not the connection, and matches the first note's author.
    const threadAuthor = link.author as { email: string };
    expect(threadAuthor.email).toBe("ann@x.com");
    expect(threadAuthor).toEqual((link.notes![0] as { author: unknown }).author);
  });

  it("skips drafts and returns empty link when only drafts exist", () => {
    const link = transformOutlookConversation({
      ...base,
      messages: [msg({ isDraft: true })],
    });
    expect(link.notes).toHaveLength(0);
  });

  it("suppresses via-rewritten display names on the From contact", () => {
    const link = transformOutlookConversation({
      ...base,
      messages: [
        msg({
          from: {
            emailAddress: {
              name: "Cloudflare via Plot Team",
              address: "team@plot.day",
            },
          },
        }),
      ],
    });
    const team = (
      link.accessContacts as Array<{ email: string; name?: string }>
    ).find((c) => c.email === "team@plot.day");
    expect(team?.name).toBeUndefined();
  });

  it("emits fileRef actions for non-inline file attachments only", () => {
    const atts = new Map<string, GraphAttachmentMeta[]>([
      [
        "id-1",
        [
          {
            id: "a1",
            name: "doc.pdf",
            contentType: "application/pdf",
            size: 123,
            isInline: false,
            odataType: "#microsoft.graph.fileAttachment",
          },
          {
            id: "a2",
            name: "logo.png",
            contentType: "image/png",
            size: 5,
            isInline: true,
            odataType: "#microsoft.graph.fileAttachment",
          },
          {
            id: "a3",
            name: "evt",
            contentType: null,
            size: null,
            isInline: false,
            odataType: "#microsoft.graph.itemAttachment",
          },
        ],
      ],
    ]);
    const link = transformOutlookConversation({
      ...base,
      attachmentsByMessageId: atts,
      messages: [msg({ hasAttachments: true })],
    });
    const actions = (link.notes![0] as { actions: Array<{ ref: string }> })
      .actions;
    expect(actions).toHaveLength(1);
    expect(actions[0].ref).toBe("id-1:a1");
  });
});

describe("conversation state helpers", () => {
  it("unread when any non-draft message is unread", () => {
    expect(isConversationUnread([msg({}), msg({ isRead: false })])).toBe(true);
    expect(
      isConversationUnread([msg({}), msg({ isRead: false, isDraft: true })])
    ).toBe(false);
  });
  it("flagged when any message is flagged", () => {
    expect(isConversationFlagged([msg({ flag: { flagStatus: "flagged" } })])).toBe(
      true
    );
    expect(isConversationFlagged([msg({})])).toBe(false);
  });
});

describe("small helpers", () => {
  it("odataQuote doubles single quotes", () => {
    expect(odataQuote("a'b")).toBe("'a''b'");
  });
  it("recipientEmails skips blanks", () => {
    expect(
      recipientEmails([
        { emailAddress: { address: " a@b.c " } },
        { emailAddress: {} },
      ])
    ).toEqual(["a@b.c"]);
  });
  it("isViaRewrittenName", () => {
    expect(isViaRewrittenName("X via Team")).toBe(true);
    expect(isViaRewrittenName("Xavier")).toBe(false);
  });
  it("sortConversation orders oldest first", () => {
    const out = sortConversation([
      msg({ id: "b", receivedDateTime: "2026-06-02T00:00:00Z" }),
      msg({ id: "a", receivedDateTime: "2026-06-01T00:00:00Z" }),
    ]);
    expect(out.map((m) => m.id)).toEqual(["a", "b"]);
  });
  it("conversationSource lowercases the mailbox", () => {
    expect(conversationSource("A@B.com", "c1")).toBe("outlook-mail:a@b.com:c1");
  });
});

describe("transformOutlookConversation sender classification", () => {
  const base = {
    attachmentsByMessageId: new Map<string, GraphAttachmentMeta[]>(),
    accountEmail: "me@work.com",
  };

  it("marks a no-reply From sender contact as automated", () => {
    const link = transformOutlookConversation({
      ...base,
      messages: [
        msg({
          from: {
            emailAddress: {
              name: "Susan Braun",
              address: "notify@payments.interac.ca",
            },
          },
        }),
      ],
    });
    const sender = (
      link.accessContacts as Array<{ email: string; automated?: boolean }>
    ).find((c) => c.email === "notify@payments.interac.ca");
    expect(sender?.automated).toBe(true);
    const author = link.notes![0].author as {
      email?: string;
      automated?: boolean;
    };
    expect(author.automated).toBe(true);
  });

  it("does not mark an ordinary From sender as automated", () => {
    const link = transformOutlookConversation({
      ...base,
      messages: [
        msg({ from: { emailAddress: { name: "Bob", address: "bob@company.com" } } }),
      ],
    });
    const sender = (
      link.accessContacts as Array<{ email: string; automated?: boolean }>
    ).find((c) => c.email === "bob@company.com");
    expect(sender?.automated).toBeFalsy();
  });
});

describe("GraphMailApi queries", () => {
  it("getConversationMessages requests meeting fields + expands event", async () => {
    const calls: Array<Record<string, string> | undefined> = [];
    const api = new GraphMailApi("tok");
    api.call = async (
      _method: string,
      _url: string,
      params?: Record<string, string>
    ) => {
      calls.push(params);
      return { value: [] };
    };
    await api.getConversationMessages("conv-1");
    expect(calls[0]?.$select).toContain("meetingMessageType");
    expect(calls[0]?.$select).toContain("meetingRequestType");
    expect(calls[0]?.$expand).toBe("event($select=iCalUId)");
  });

  it("getMessagesPage requests meeting fields + expands event on the non-nextLink branch", async () => {
    const calls: Array<Record<string, string> | undefined> = [];
    const api = new GraphMailApi("tok");
    api.call = async (
      _method: string,
      _url: string,
      params?: Record<string, string>
    ) => {
      calls.push(params);
      return { value: [] };
    };
    await api.getMessagesPage({ folderId: "f-inbox" });
    expect(calls[0]?.$select).toContain("meetingMessageType");
    expect(calls[0]?.$expand).toBe("event($select=iCalUId)");
  });
});

describe("classifyOutlookCalendar", () => {
  const header = (name: string, value: string): GraphHeader => ({ name, value });

  it("reply chain via X-Plot-Event-UID header (checked before any message signal)", () => {
    expect(
      classifyOutlookCalendar([], [header("x-plot-event-uid", "uid-1")])
    ).toEqual({ uid: "uid-1", kind: "reply" });
  });

  it("header match is case-insensitive", () => {
    expect(
      classifyOutlookCalendar([], [header("X-PLOT-EVENT-UID", "uid-3")])
    ).toEqual({ uid: "uid-3", kind: "reply" });
  });

  it("header takes priority over a message-derived cancel/update signal", () => {
    expect(
      classifyOutlookCalendar(
        [
          msg({
            meetingMessageType: "meetingCancelled",
            event: { iCalUId: "uid-msg" },
          }),
        ],
        [header("X-Plot-Event-UID", "uid-header")]
      )
    ).toEqual({ uid: "uid-header", kind: "reply" });
  });

  it("update: meetingRequest fullUpdate", () => {
    expect(
      classifyOutlookCalendar(
        [
          msg({
            meetingMessageType: "meetingRequest",
            meetingRequestType: "fullUpdate",
            event: { iCalUId: "uid-1" },
          }),
        ],
        null
      )
    ).toEqual({ uid: "uid-1", kind: "update" });
  });

  it("update: meetingRequest informationalUpdate", () => {
    expect(
      classifyOutlookCalendar(
        [
          msg({
            meetingMessageType: "meetingRequest",
            meetingRequestType: "informationalUpdate",
            event: { iCalUId: "uid-2" },
          }),
        ],
        null
      )
    ).toEqual({ uid: "uid-2", kind: "update" });
  });

  it("cancel: meetingCancelled", () => {
    expect(
      classifyOutlookCalendar(
        [
          msg({
            meetingMessageType: "meetingCancelled",
            event: { iCalUId: "uid-1" },
          }),
        ],
        null
      )
    ).toEqual({ uid: "uid-1", kind: "cancel" });
  });

  it("skips new invite + RSVP", () => {
    expect(
      classifyOutlookCalendar(
        [
          msg({
            meetingMessageType: "meetingRequest",
            meetingRequestType: "newMeetingRequest",
            event: { iCalUId: "u" },
          }),
        ],
        null
      )
    ).toBeNull();
    expect(
      classifyOutlookCalendar(
        [msg({ meetingMessageType: "meetingAccepted", event: { iCalUId: "u" } })],
        null
      )
    ).toBeNull();
  });

  it("skips a qualifying meetingMessageType without an event.iCalUId", () => {
    expect(
      classifyOutlookCalendar(
        [msg({ meetingMessageType: "meetingCancelled", event: undefined })],
        null
      )
    ).toBeNull();
  });

  it("returns null for plain messages with no calendar signal at all", () => {
    expect(classifyOutlookCalendar([msg({})], null)).toBeNull();
    expect(classifyOutlookCalendar([], null)).toBeNull();
    expect(classifyOutlookCalendar([], [])).toBeNull();
  });

  it("scans past a non-qualifying message to find a later qualifying one", () => {
    expect(
      classifyOutlookCalendar(
        [
          msg({ id: "id-1", meetingMessageType: undefined }),
          msg({
            id: "id-2",
            meetingMessageType: "meetingCancelled",
            event: { iCalUId: "uid-later" },
          }),
        ],
        null
      )
    ).toEqual({ uid: "uid-later", kind: "cancel" });
  });
});
