import { describe, expect, it } from "vitest";
import { slackFacets } from "./slack-facets";
import type { SlackMessage } from "./slack-api";

function m(overrides: Partial<SlackMessage> = {}): SlackMessage {
  return { type: "message", ts: "1.0", text: "hi", ...overrides };
}

describe("slackFacets", () => {
  it("treats a DM human message as chat/human/direct", () => {
    expect(slackFacets(m({ user: "U1", text: "hey there" }), "D123")).toEqual({
      format: "chat",
      automation: "human",
      reach: "direct",
    });
  });
  it("treats a channel post as reach=list", () => {
    expect(slackFacets(m({ user: "U1" }), "C123").reach).toBe("list");
  });
  it("flags a bot message automated", () => {
    expect(slackFacets(m({ bot_id: "B1", subtype: "bot_message" }), "C123").automation).toBe("automated");
  });
  it("a long post becomes a message, not chat", () => {
    expect(slackFacets(m({ user: "U1", text: "x".repeat(1500) }), "C123").format).toBe("message");
  });
  it("treats a group DM (G-prefix) as reach=direct", () => {
    expect(slackFacets(m({ user: "U1" }), "G123").reach).toBe("direct");
  });
  it("treats a message with no user as automated", () => {
    expect(slackFacets(m({ user: undefined }), "C123").automation).toBe("automated");
  });
});
