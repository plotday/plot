import { describe, expect, it } from "vitest";

import type { Message, MessageSender } from "./google-chat-api";
import { transformChatThread } from "./google-chat-api";
import {
  googleChatDmFacets,
  googleChatThreadFacets,
} from "./google-chat-facets";

let counter = 0;

function chatMessage(overrides: {
  text?: string;
  sender?: Partial<MessageSender>;
} = {}): Message {
  counter += 1;
  return {
    name: `spaces/SPACE1/messages/msg${counter}`,
    sender: {
      name: `users/${100 + counter}`,
      displayName: "Ada Lovelace",
      type: "HUMAN",
      ...overrides.sender,
    } as MessageSender,
    createTime: "2026-08-07T12:00:00Z",
    text: overrides.text ?? "hello there",
    thread: { name: "spaces/SPACE1/threads/thread1" },
    space: { name: "spaces/SPACE1" },
  };
}

describe("googleChatThreadFacets", () => {
  it("classifies a short human parent as a direct-format chat in a list context", () => {
    const facets = googleChatThreadFacets(chatMessage());
    expect(facets).toEqual({
      format: "chat",
      automation: "human",
      reach: "list",
    });
  });

  it("classifies a bot-sent parent as automated", () => {
    const facets = googleChatThreadFacets(
      chatMessage({ sender: { type: "BOT", displayName: "Build Bot" } })
    );
    expect(facets.automation).toBe("automated");
  });

  it("treats a long parent as a message rather than a chat", () => {
    const facets = googleChatThreadFacets(
      chatMessage({ text: "a".repeat(1001) })
    );
    expect(facets.format).toBe("message");
  });

  it("falls open to human when the sender type is missing", () => {
    const message = chatMessage();
    delete (message.sender as Partial<MessageSender>).type;
    expect(googleChatThreadFacets(message).automation).toBe("human");
  });
});

describe("googleChatDmFacets", () => {
  it("classifies a human conversation as a direct human chat", () => {
    const facets = googleChatDmFacets([chatMessage(), chatMessage()]);
    expect(facets).toEqual({
      format: "chat",
      automation: "human",
      reach: "direct",
    });
  });

  it("classifies an all-bot conversation as automated", () => {
    const bot = { sender: { type: "BOT" as const, displayName: "Reminder Bot" } };
    const facets = googleChatDmFacets([chatMessage(bot), chatMessage(bot)]);
    expect(facets.automation).toBe("automated");
  });

  it("stays human when even one message is human-shaped", () => {
    const bot = { sender: { type: "BOT" as const, displayName: "Reminder Bot" } };
    const facets = googleChatDmFacets([
      chatMessage(bot),
      chatMessage(),
      chatMessage(bot),
    ]);
    expect(facets.automation).toBe("human");
  });

  it("falls open to human for an empty batch", () => {
    expect(googleChatDmFacets([]).automation).toBe("human");
  });

  it("keeps chat format even for a long message", () => {
    const facets = googleChatDmFacets([chatMessage({ text: "a".repeat(5000) })]);
    expect(facets.format).toBe("chat");
  });
});

describe("transformChatThread facet stamping", () => {
  it("stamps list-reach facets on a named-space thread", () => {
    const link = transformChatThread([chatMessage()], "SPACE1", true, "space");
    expect(link.facets).toEqual({
      format: "chat",
      automation: "human",
      reach: "list",
    });
  });

  it("stamps direct-reach facets on a DM thread", () => {
    const link = transformChatThread([chatMessage()], "DM1", true, "dm");
    expect(link.facets).toEqual({
      format: "chat",
      automation: "human",
      reach: "direct",
    });
  });

  it("judges a DM batch as a whole, not just the parent", () => {
    const bot = { sender: { type: "BOT" as const, displayName: "Reminder Bot" } };
    const link = transformChatThread(
      [chatMessage(bot), chatMessage()],
      "DM1",
      true,
      "dm"
    );
    expect(link.facets?.automation).toBe("human");
  });
});
