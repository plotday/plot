import { describe, expect, it, vi } from "vitest";

import type { CreateLinkDraft, Uuid } from "@plotday/twister";

/**
 * Regression coverage for two outbound-header sites that had no test
 * exercising Graph recipient display names: a plain mail reply resolved
 * from a curated (platform-resolved) recipient, and a brand-new compose
 * (non-forward) send. Both previously built `{ emailAddress: { address } }`
 * only — dropping any display name Graph would otherwise show.
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

import { onCreateLinkFn, onNoteCreatedFn } from "./sync";

function makeHost(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(
    Object.entries({
      user_email: "me@work.com",
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

function replyThread() {
  return {
    id: "T",
    meta: { channelId: "inbox", conversationId: "conv-1" },
    accessContacts: [{ id: "c-me", email: "me@work.com" }],
  } as never;
}

/** A note whose `recipients` is the runtime's platform-resolved (curated) list
 *  — Case 1 in `resolveOutboundReplyRecipients`, the only case that carries a
 *  display `name` through to the connector. */
function curatedReplyNote() {
  return {
    id: "n1",
    author: { id: "c-me" },
    content: "Sounds good",
    accessContacts: null,
    recipients: [
      {
        id: "c-dana",
        name: "Dana Sproule",
        externalAccountId: "dana@x.com",
        role: null,
      },
    ],
    actions: [],
  } as never;
}

describe("outlook onNoteCreatedFn — plain mail reply carries recipient display names", () => {
  it("includes the display name for a curated (platform-resolved) recipient", async () => {
    graphApi.getConversationMessages.mockResolvedValue([
      {
        id: "msg-1",
        isDraft: false,
        from: { emailAddress: { address: "dana@x.com", name: "Dana Sproule" } },
        toRecipients: [{ emailAddress: { address: "me@work.com" } }],
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

    const { host } = makeHost();

    await onNoteCreatedFn(host, curatedReplyNote(), replyThread());

    expect(graphApi.updateMessage).toHaveBeenCalledTimes(1);
    const updateBody = graphApi.updateMessage.mock.calls[0][1];
    expect(updateBody.toRecipients).toContainEqual({
      emailAddress: { address: "dana@x.com", name: "Dana Sproule" },
    });
  });
});

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

describe("outlook onCreateLinkFn — plain compose carries recipient display names", () => {
  it("includes the display name for a draft.recipients entry in the outbound To header", async () => {
    graphApi.createDraft.mockResolvedValue({
      id: "cd1",
      internetMessageId: "<imid-2>",
      conversationId: "conv-2",
    });
    graphApi.send.mockResolvedValue(undefined);

    const { host } = makeHost();

    const link = await onCreateLinkFn(
      host,
      composeDraft({
        recipients: [
          {
            id: "c-dana" as Uuid,
            name: "Dana Sproule",
            externalAccountId: "dana@x.com",
            role: null,
          },
        ],
      })
    );

    expect(graphApi.createDraft).toHaveBeenCalledTimes(1);
    const body = graphApi.createDraft.mock.calls[0][0];
    expect(body.toRecipients).toContainEqual({
      emailAddress: { address: "dana@x.com", name: "Dana Sproule" },
    });
    expect(link?.type).toBe("email");
  });
});
