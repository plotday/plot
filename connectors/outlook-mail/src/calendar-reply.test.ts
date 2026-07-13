import { describe, expect, it, vi } from "vitest";

const { graphApi } = vi.hoisted(() => ({
  graphApi: {
    createDraft: vi.fn(),
    createReplyDraft: vi.fn(),
    updateMessage: vi.fn(),
    getMessage: vi.fn(),
    send: vi.fn(),
  },
}));
vi.mock("./graph-mail-api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./graph-mail-api")>();
  return { ...actual, GraphMailApi: vi.fn(() => graphApi) };
});
// ensureUserEmailFn reads user_email from store; seed it to avoid a getProfile call.
import { onNoteCreatedFn } from "./sync";

function makeHost(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(
    Object.entries({
      user_email: "me@example.com",
      enabled_channels: ["inbox"],
      ...initial,
    })
  );
  const store = {
    get: vi.fn(async (k: string) => (map.has(k) ? map.get(k) : null)),
    set: vi.fn(async (k: string, v: unknown) => {
      map.set(k, v);
    }),
    clear: vi.fn(async (k: string) => {
      map.delete(k);
    }),
    list: vi.fn(async (p: string) =>
      [...map.keys()].filter((k) => k.startsWith(p))
    ),
    acquireLock: vi.fn(async () => true),
    releaseLock: vi.fn(async () => {}),
  };
  return {
    map,
    host: {
      id: "ti-1",
      set: store.set,
      get: store.get,
      clear: store.clear,
      tools: {
        store,
        integrations: { get: vi.fn(async () => ({ token: "tok", scopes: [] })) },
        files: { read: vi.fn() },
      },
    } as never,
  };
}
function calThread() {
  return {
    id: "T",
    title: "Weekly sync",
    meta: { calendarId: "cal-1", iCalUId: "uid-123", syncableId: "cal-1" },
    accessContacts: [
      { id: "c-me", email: "me@example.com" },
      { id: "c-bob", email: "bob@x.com" },
    ],
  } as never;
}
function replyNote(externalIds: string[]) {
  return {
    id: "n1",
    author: { id: "c-me" },
    content: "See you there",
    accessContacts: null,
    recipients: externalIds.map((e) => ({
      id: e,
      name: null,
      externalAccountId: e,
      role: null,
    })),
    actions: [],
  } as never;
}

describe("outlook onNoteCreatedFn — calendar event thread", () => {
  it("first reply: createDraft with X-Plot-Event-UID header + all attendees, then send", async () => {
    graphApi.createDraft.mockResolvedValue({
      id: "d1",
      conversationId: "conv-1",
      internetMessageId: "<imid-1>",
    });
    graphApi.send.mockResolvedValue(undefined);
    const { host, map } = makeHost();

    const res = await onNoteCreatedFn(host, replyNote(["bob@x.com"]), calThread());

    expect(graphApi.createDraft).toHaveBeenCalledTimes(1);
    const body = graphApi.createDraft.mock.calls[0][0];
    expect(body.internetMessageHeaders).toEqual([
      { name: "x-plot-event-uid", value: "uid-123" },
    ]);
    expect(body.toRecipients).toEqual([{ emailAddress: { address: "bob@x.com" } }]);
    expect(graphApi.send).toHaveBeenCalledWith("d1");
    expect(map.get("cal-reply:uid-123")).toMatchObject({ conversationId: "conv-1" });
    expect(res).toEqual({ key: "<imid-1>" });
  });

  it("second reply: threads via createReplyDraft into stored conversation", async () => {
    graphApi.createReplyDraft.mockResolvedValue({ id: "d2", internetMessageId: "<imid-2>" });
    graphApi.updateMessage.mockResolvedValue(undefined);
    graphApi.getMessage.mockResolvedValue({
      id: "d2",
      internetMessageId: "<imid-2>",
      conversationId: "conv-1",
    });
    graphApi.send.mockResolvedValue(undefined);
    const { host } = makeHost({
      "cal-reply:uid-123": { conversationId: "conv-1", lastMessageId: "seed-msg" },
    });

    await onNoteCreatedFn(host, replyNote(["bob@x.com"]), calThread());

    expect(graphApi.createReplyDraft).toHaveBeenCalledWith("seed-msg");
    expect(graphApi.send).toHaveBeenCalledWith("d2");
  });
});
