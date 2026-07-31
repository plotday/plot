import { describe, expect, it, vi } from "vitest";
import {
  SlackApi,
  transformSlackThread,
  syncSlackChannel,
  type SlackMessage,
  type SlackUserInfoMap,
} from "./slack-api";

describe("transformSlackThread", () => {
  it("attributes the thread to the root message's sender", () => {
    const messages: SlackMessage[] = [
      { type: "message", ts: "1000.0001", user: "U_ROOT", text: "Hello team" },
      { type: "message", ts: "1000.0002", user: "U_REPLY", text: "Hi back" },
    ];
    const userInfos: SlackUserInfoMap = new Map([
      [
        "U_ROOT",
        { name: "Root Person", email: "root@example.com", handle: "root" },
      ],
      [
        "U_REPLY",
        { name: "Reply Person", email: "reply@example.com", handle: "reply" },
      ],
    ]);

    const link = transformSlackThread(messages, "C123", userInfos);

    // The link (thread) author must be the first/root message's sender, not
    // the connector, and must match that message's own note author.
    expect(link.author).toEqual({
      name: "Root Person",
      email: "root@example.com",
      source: { accountId: "U_ROOT", descriptor: "@root" },
    });
    expect(link.author).toEqual(link.notes?.[0]?.author);
  });

  it("falls back to the raw id as a healing placeholder with no user info", () => {
    const messages: SlackMessage[] = [
      { type: "message", ts: "2000.0001", bot_id: "B_BOT", text: "Automated" },
    ];

    const link = transformSlackThread(messages, "C123");

    // No users.info available for B_BOT, so the author name is the raw id and
    // its source keys on that same id. The API treats a contact whose name
    // equals its account id as an unresolved placeholder and replaces it with
    // the real name as soon as users.info succeeds — so this attributes the
    // note to a distinct person rather than to the connection, and heals.
    expect(link.author).toEqual({
      name: "B_BOT",
      source: { accountId: "B_BOT" },
    });
    expect(link.notes?.[0]?.author).toEqual(link.author);
  });

  it("does not ask the platform to re-group the messages", () => {
    // Outside a direct conversation, Slack's own reply threads are a real,
    // user-visible grouping. Folding consecutive messages on top of that
    // would merge separate conversations that happen to run back to back.
    const link = transformSlackThread(
      [{ type: "message", ts: "3000.0001", user: "U1", text: "Standalone" }],
      "C123"
    );

    expect(
      (link as unknown as { autoThread?: unknown }).autoThread
    ).toBeUndefined();
  });
});

describe("SlackApi.getConversationInfo", () => {
  it("returns the caller's last_read cursor", async () => {
    const api = new SlackApi("xoxp-test");
    const call = vi
      .spyOn(api, "call")
      .mockResolvedValue({ channel: { id: "C1", last_read: "1700000000.000001" } });

    await expect(api.getConversationInfo("C1")).resolves.toEqual({
      lastRead: "1700000000.000001",
    });
    expect(call).toHaveBeenCalledWith("conversations.info", { channel: "C1" });
  });

  it("returns null when Slack omits last_read rather than inventing one", async () => {
    const api = new SlackApi("xoxp-test");
    vi.spyOn(api, "call").mockResolvedValue({ channel: { id: "C1" } });

    await expect(api.getConversationInfo("C1")).resolves.toEqual({ lastRead: null });
  });
});

describe("SlackApi.markConversationRead", () => {
  it("marks the conversation read at the given ts", async () => {
    const api = new SlackApi("xoxp-test");
    const call = vi.spyOn(api, "call").mockResolvedValue({ ok: true });

    await api.markConversationRead("D1", "1700000000.000001");

    expect(call).toHaveBeenCalledWith("conversations.mark", {
      channel: "D1",
      ts: "1700000000.000001",
    });
  });
});

describe("syncSlackChannel thread parent", () => {
  it("keeps the conversations.replies parent so its thread cursor survives", async () => {
    const historyParent = {
      type: "message",
      ts: "1700000000.000001",
      thread_ts: "1700000000.000001",
      user: "U1",
      text: "parent",
      reply_count: 1,
    };
    const repliesParent = { ...historyParent, unread_count: 0, subscribed: true };
    const reply = {
      type: "message",
      ts: "1700000002.000000",
      thread_ts: "1700000000.000001",
      user: "U2",
      text: "reply",
    };

    const api = {
      getConversationHistory: vi
        .fn()
        .mockResolvedValue({ messages: [historyParent], hasMore: false }),
      getThread: vi.fn().mockResolvedValue([repliesParent, reply]),
      getThreadReplies: vi.fn(),
    };

    const { threads } = await syncSlackChannel(api as never, { channelId: "C1" });

    expect(threads).toHaveLength(1);
    expect(threads[0]![0]!.unread_count).toBe(0);
    expect(threads[0]![1]!.ts).toBe("1700000002.000000");
    expect(api.getThreadReplies).not.toHaveBeenCalled();
  });

  it("falls back to the history parent when conversations.replies returns nothing", async () => {
    const historyParent = {
      type: "message",
      ts: "1700000000.000001",
      thread_ts: "1700000000.000001",
      user: "U1",
      text: "parent",
      reply_count: 1,
    };
    const api = {
      getConversationHistory: vi
        .fn()
        .mockResolvedValue({ messages: [historyParent], hasMore: false }),
      getThread: vi.fn().mockResolvedValue([]),
    };

    const { threads } = await syncSlackChannel(api as never, { channelId: "C1" });

    expect(threads).toEqual([[historyParent]]);
  });
});
