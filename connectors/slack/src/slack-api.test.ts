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

  it("omits the author when the root message has no user info", () => {
    const messages: SlackMessage[] = [
      { type: "message", ts: "2000.0001", bot_id: "B_BOT", text: "Automated" },
    ];

    const link = transformSlackThread(messages, "C123");

    // No users.info available for B_BOT, so slackUserToNewActor returns
    // null rather than poisoning the contact with the raw id as its name.
    expect(link.author).toBeUndefined();
    expect(link.notes?.[0]?.author).toBeUndefined();
  });
});
