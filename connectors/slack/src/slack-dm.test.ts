import { describe, expect, it } from "vitest";

import { assembleSlackDmLink } from "./slack-dm";
import type { SlackMessage, SlackUserInfo } from "./slack-api";

function msg(ts: string, user: string, text: string, threadTs?: string): SlackMessage {
  return { type: "message", ts, user, text, ...(threadTs ? { thread_ts: threadTs } : {}) };
}

describe("assembleSlackDmLink", () => {
  it("keys a 1:1 DM on the counterparty", () => {
    const link = assembleSlackDmLink({
      channelId: "D111",
      counterpartyUserId: "U222",
      messages: [msg("100.1", "U222", "hi")],
      initialSync: false,
    });

    expect(link?.source).toBe("slack:person:U222");
    expect(link?.sources).toEqual(["slack:person:U222", "slack:chat:D111"]);
    expect(link?.type).toBe("dm");
    expect(link?.channelId).toBe("D111");
    expect(link?.meta?.direct).toBe(true);
  });

  it("keys a group DM on the conversation", () => {
    const link = assembleSlackDmLink({
      channelId: "G333",
      counterpartyUserId: null,
      messages: [msg("100.1", "U222", "hi all")],
      initialSync: false,
    });

    expect(link?.source).toBe("slack:chat:G333");
    expect(link?.sources).toEqual(["slack:chat:G333"]);
  });

  it("creates one note per message, oldest first, keyed on ts", () => {
    const link = assembleSlackDmLink({
      channelId: "D111",
      counterpartyUserId: "U222",
      messages: [msg("102.0", "U222", "third"), msg("100.0", "U222", "first")],
      initialSync: false,
    });

    expect(link?.notes?.map((n) => n.key)).toEqual(["100.0", "102.0"]);
    expect(link?.notes?.map((n) => n.content)).toEqual(["first", "third"]);
  });

  it("records the newest message as meta.threadTs so a to-do star has something to target", () => {
    // A DM is one permanent, ever-growing link with no single message of its
    // own, so onThreadToDo needs a message to anchor a star on. Without this,
    // starring a synced (as opposed to composed-from-Plot) DM is a silent
    // no-op — onThreadToDo bails out whenever meta.threadTs is missing.
    const link = assembleSlackDmLink({
      channelId: "D111",
      counterpartyUserId: "U222",
      messages: [msg("100.0", "U222", "first"), msg("102.0", "U222", "third")],
      initialSync: false,
    });

    expect(link?.meta?.threadTs).toBe("102.0");
  });

  it("marks a threaded reply with reNote pointing at its parent", () => {
    const link = assembleSlackDmLink({
      channelId: "D111",
      counterpartyUserId: "U222",
      messages: [msg("100.0", "U222", "parent"), msg("101.0", "U222", "reply", "100.0")],
      initialSync: false,
    });

    expect(link?.notes?.[0]?.reNote).toBeUndefined();
    expect(link?.notes?.[1]?.reNote).toEqual({ key: "100.0" });
  });

  it("does not mark a thread parent as its own reply", () => {
    const link = assembleSlackDmLink({
      channelId: "D111",
      counterpartyUserId: "U222",
      messages: [msg("100.0", "U222", "parent", "100.0")],
      initialSync: false,
    });

    expect(link?.notes?.[0]?.reNote).toBeUndefined();
  });

  it("suppresses unread and archived state on initial sync", () => {
    const link = assembleSlackDmLink({
      channelId: "D111",
      counterpartyUserId: "U222",
      messages: [msg("100.0", "U222", "hi")],
      initialSync: true,
    });

    expect(link?.unread).toBe(false);
    expect(link?.archived).toBe(false);
  });

  it("returns null when there are no messages", () => {
    expect(
      assembleSlackDmLink({
        channelId: "D111",
        counterpartyUserId: "U222",
        messages: [],
        initialSync: false,
      })
    ).toBeNull();
  });

  it("derives title from counterparty's name when userInfos is provided", () => {
    const userInfos = new Map<string, SlackUserInfo>([
      ["U222", { name: "Alice", email: "alice@example.com", handle: "alice" }],
    ]);

    const link = assembleSlackDmLink({
      channelId: "D111",
      counterpartyUserId: "U222",
      messages: [msg("100.0", "U222", "hello")],
      initialSync: false,
      userInfos,
    });

    expect(link?.title).toBe("Alice");
    expect(link?.accessContacts?.[0]?.name).toBe("Alice");
    expect(link?.accessContacts?.[0]?.email).toBe("alice@example.com");
  });

  it("sets a real author on every note", () => {
    const link = assembleSlackDmLink({
      channelId: "D111",
      counterpartyUserId: "U222",
      messages: [msg("100.0", "U222", "hi")],
      initialSync: false,
    });

    expect(link?.notes?.[0]?.author).toBeDefined();
    expect(
      link?.notes?.[0]?.author && "source" in link.notes[0].author
        ? link.notes[0].author.source?.accountId
        : undefined
    ).toBe("U222");
  });

  it("omits unread/archived (does not hardcode them) when initialSync is false", () => {
    const link = assembleSlackDmLink({
      channelId: "D111",
      counterpartyUserId: "U222",
      messages: [msg("100.0", "U222", "hi")],
      initialSync: false,
    });

    expect(link).not.toHaveProperty("unread");
    expect(link).not.toHaveProperty("archived");
  });

  it("still carries a counterparty contact and no clobbered title when userInfos hasn't resolved", () => {
    const link = assembleSlackDmLink({
      channelId: "D111",
      counterpartyUserId: "U222",
      messages: [msg("100.0", "U222", "hi")],
      initialSync: false,
      // No userInfos at all — a cold or rate-limited sync.
    });

    // CRITICAL 1: accessContacts must not vanish just because users.info
    // hasn't resolved — it's the filing signal for link creation, which
    // only happens once.
    expect(link?.accessContacts).toBeDefined();
    expect(link?.accessContacts?.[0]?.source?.accountId).toBe("U222");

    // CRITICAL 2: title must be omitted (preserving any existing stored
    // title) rather than clobbered with a placeholder — neither the raw
    // Slack user id nor a generic constant string.
    expect(link).not.toHaveProperty("title");
  });

  it("carries file/image attachments as fileRef actions", () => {
    const message: SlackMessage = {
      type: "message",
      ts: "100.0",
      user: "U222",
      text: "check this out",
      files: [
        {
          id: "F123",
          name: "screenshot.png",
          mimetype: "image/png",
          size: 4096,
          original_w: 800,
          original_h: 600,
        },
      ],
    };

    const link = assembleSlackDmLink({
      channelId: "D111",
      counterpartyUserId: "U222",
      messages: [message],
      initialSync: false,
    });

    expect(link?.notes?.[0]?.actions).toEqual([
      {
        type: "fileRef",
        ref: "F123",
        fileName: "screenshot.png",
        fileSize: 4096,
        mimeType: "image/png",
        imageWidth: 800,
        imageHeight: 600,
      },
    ]);
  });

  it("sets checkForTasks on every note", () => {
    const link = assembleSlackDmLink({
      channelId: "D111",
      counterpartyUserId: "U222",
      messages: [msg("100.0", "U222", "hi")],
      initialSync: false,
    });

    expect(link?.notes?.[0]?.checkForTasks).toBe(true);
  });

  it("sets a canonical Slack sourceUrl anchored on the latest message", () => {
    const link = assembleSlackDmLink({
      channelId: "D111",
      counterpartyUserId: "U222",
      messages: [msg("100.0", "U222", "first"), msg("102.0", "U222", "second")],
      initialSync: false,
    });

    expect(link?.sourceUrl).toBe(
      "https://slack.com/app_redirect?channel=D111&message_ts=102.0"
    );
  });
});
