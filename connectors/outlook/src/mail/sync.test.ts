import { beforeEach, describe, expect, it, vi } from "vitest";

import type { CreateLinkDraft } from "@plotday/twister";

/**
 * Regression coverage for Gmail-alias-aware self-exclusion in the Outlook
 * connector. The connected Outlook mailbox routinely forwards from or
 * sends-as a Gmail address, and Gmail ignores dots (and anything after a
 * "+") in the local part — so a header may address the user through a
 * variant that never string-matches the connected mailbox
 * ("krisbraun@gmail.com" vs "kris.braun@gmail.com"). Before this fix, a
 * plain `toLowerCase()` comparison treated that variant as a third-party
 * recipient and replied to the user's own address.
 */
const { graphApi } = vi.hoisted(() => ({
  graphApi: {
    createDraft: vi.fn(),
    createReplyDraft: vi.fn(),
    updateMessage: vi.fn(),
    getMessage: vi.fn(),
    getConversationMessages: vi.fn(),
    send: vi.fn(),
  },
}));
vi.mock("./graph-mail-api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./graph-mail-api")>();
  return { ...actual, GraphMailApi: vi.fn(() => graphApi) };
});
// ensureUserEmailFn reads user_email from store; seed it to avoid a getProfile call.
import { onCreateLinkFn, onNoteCreatedFn } from "./sync";

beforeEach(() => {
  vi.clearAllMocks();
});

function makeHost(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(
    Object.entries({
      enabled_channels: ["inbox"],
      ...initial,
    })
  );
  return {
    map,
    host: {
      id: "ti-1",
      get: vi.fn(async (k: string) => (map.has(k) ? map.get(k) : null)),
      set: vi.fn(async (k: string, v: unknown) => {
        map.set(k, v);
      }),
      clear: vi.fn(async (k: string) => {
        map.delete(k);
      }),
      tools: {
        integrations: { get: vi.fn(async () => ({ token: "tok", scopes: [] })) },
        files: { read: vi.fn() },
      },
    } as never,
  };
}

function replyThread(accountEmail: string) {
  return {
    id: "T",
    meta: { channelId: "inbox", conversationId: "conv-1" },
    accessContacts: [{ id: "c-me", email: accountEmail }],
  } as never;
}

/** A plain reply note with no curated recipients/access constraint — drives
 *  the header-derived reply-all fallback (Case 3 in resolveOutboundReplyRecipients). */
function replyAllNote() {
  return {
    id: "n1",
    author: { id: "c-me" },
    content: "Sounds good",
    accessContacts: null,
    recipients: null,
    actions: [],
  } as never;
}

describe("onNoteCreatedFn — Gmail alias addressed to the connected mailbox", () => {
  it("does not address the reply back to a dot-variant of the account", async () => {
    // The connected Outlook mailbox forwards from a Gmail address; the
    // original message addressed a dot-variant of it. That variant is the
    // user, so it must not appear as an outbound recipient.
    const accountEmail = "kris.braun@gmail.com";
    graphApi.getConversationMessages.mockResolvedValue([
      {
        id: "msg-1",
        isDraft: false,
        from: { emailAddress: { address: "annie@example.com" } },
        toRecipients: [{ emailAddress: { address: "krisbraun@gmail.com" } }],
        ccRecipients: [],
      },
    ]);
    graphApi.createReplyDraft.mockResolvedValue({
      id: "d1",
      internetMessageId: "<imid-1>",
    });
    graphApi.updateMessage.mockResolvedValue(undefined);
    graphApi.getMessage.mockResolvedValue({
      id: "d1",
      internetMessageId: "<imid-1>",
      conversationId: "conv-1",
    });
    graphApi.send.mockResolvedValue(undefined);

    const { host } = makeHost({ user_email: accountEmail });

    await onNoteCreatedFn(host, replyAllNote(), replyThread(accountEmail));

    expect(graphApi.updateMessage).toHaveBeenCalledTimes(1);
    const updateBody = graphApi.updateMessage.mock.calls[0][1];
    expect(updateBody.toRecipients).toEqual([
      { emailAddress: { address: "annie@example.com" } },
    ]);
    expect(updateBody.ccRecipients).toEqual([]);
  });
});

function calThread(over: Record<string, unknown> = {}) {
  return {
    id: "T",
    title: "Weekly sync",
    meta: { calendarId: "cal-1", iCalUId: "uid-123", syncableId: "cal-1" },
    accessContacts: [
      { id: "c-me", email: "kris.braun@gmail.com" },
      { id: "c-alias", email: "krisbraun@gmail.com" },
    ],
    ...over,
  } as never;
}

function curatedCalReplyNote(
  recipients: Array<{ externalAccountId: string; role: string | null }>,
  over: Record<string, unknown> = {}
) {
  return {
    id: "n1",
    author: { id: "c-me" },
    content: "See you there",
    accessContacts: ["c-alias"],
    recipients: recipients.map((r) => ({
      id: r.externalAccountId,
      name: null,
      externalAccountId: r.externalAccountId,
      role: r.role,
    })),
    actions: [],
    ...over,
  } as never;
}

function composeDraft(overrides: Partial<CreateLinkDraft> = {}): CreateLinkDraft {
  return {
    channelId: "inbox",
    type: "email",
    status: null,
    title: "Q3 planning",
    noteContent: "Let's sync on this",
    contacts: [],
    recipients: [],
    inviteEmails: [],
    ...overrides,
  } as CreateLinkDraft;
}

describe("onCreateLinkFn — recipient dedupe recognizes Gmail dot variants", () => {
  it("does not send two copies to the same Gmail mailbox reached via a dot variant", async () => {
    // A picker-resolved recipient ("dana@gmail.com") and a separately typed
    // invite address ("d.ana@gmail.com") are the same Gmail mailbox — Gmail
    // ignores dots in the local part. The dedupe key must recognize this
    // ROW-identity (canonicalizeEmail), not just an exact lowercase match,
    // or the compose sends the same person two copies.
    graphApi.createDraft.mockResolvedValue({
      id: "cd1",
      internetMessageId: "<imid-3>",
      conversationId: "conv-3",
    });
    graphApi.send.mockResolvedValue(undefined);
    const { host } = makeHost({ user_email: "me@work.com" });

    await onCreateLinkFn(
      host,
      composeDraft({
        recipients: [
          {
            id: "c-dana",
            name: null,
            externalAccountId: "dana@gmail.com",
            role: null,
          },
        ] as never,
        inviteEmails: ["d.ana@gmail.com"],
      })
    );

    expect(graphApi.createDraft).toHaveBeenCalledTimes(1);
    const body = graphApi.createDraft.mock.calls[0][0];
    expect(body.toRecipients).toHaveLength(1);
    expect(body.toRecipients).toEqual([
      { emailAddress: { address: "dana@gmail.com" } },
    ]);
  });
});

describe("onNoteCreatedFn — calendar reply whose curated recipients are all self", () => {
  it("resolves to zero recipients and surfaces a deliveryError, rather than emailing the organizer their own reply", async () => {
    // The calendar-reply call site passes empty headerTo/headerCc and no
    // headerFrom to resolveOutboundReplyRecipients, so the self-reply
    // fallback there can never fire for this path. If the note's curated
    // recipient set is entirely dot/+tag variants of the organizer's own
    // connected mailbox, the reply must resolve to no recipients rather
    // than being sent back to the organizer.
    const { host } = makeHost({ user_email: "kris.braun@gmail.com" });

    const res = await onNoteCreatedFn(
      host,
      curatedCalReplyNote([{ externalAccountId: "krisbraun@gmail.com", role: null }]),
      calThread()
    );

    expect(graphApi.createDraft).not.toHaveBeenCalled();
    expect(res).toEqual({
      deliveryError: {
        code: "no_recipients",
        message: "This reply had no deliverable recipients.",
      },
    });
  });
});
