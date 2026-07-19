import { describe, expect, it } from "vitest";
import {
  transformSlackThread,
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
});
