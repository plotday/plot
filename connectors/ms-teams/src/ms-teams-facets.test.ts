import { describe, expect, it } from "vitest";

import type { TeamsMessage } from "./graph-api";
import {
  teamsChannelFacets,
  teamsDmFacets,
  transformChannelThread,
  transformDmThread,
} from "./graph-api";

let counter = 0;

function teamsMessage(overrides: Partial<TeamsMessage> = {}): TeamsMessage {
  counter += 1;
  return {
    id: `msg${counter}`,
    createdDateTime: "2026-08-07T12:00:00Z",
    messageType: "message",
    from: { user: { id: `user${counter}`, displayName: "Ada Lovelace" } },
    body: { contentType: "html", content: "<p>hello there</p>" },
    ...overrides,
  };
}

function appMessage(overrides: Partial<TeamsMessage> = {}): TeamsMessage {
  return teamsMessage({
    from: { application: { id: "app1", displayName: "Build Bot" } },
    ...overrides,
  });
}

describe("teamsChannelFacets", () => {
  it("classifies a short human parent as a chat in a list context", () => {
    expect(teamsChannelFacets(teamsMessage())).toEqual({
      format: "chat",
      automation: "human",
      reach: "list",
    });
  });

  it("classifies an application-sent parent as automated", () => {
    expect(teamsChannelFacets(appMessage()).automation).toBe("automated");
  });

  it("classifies a sender-less parent as automated", () => {
    const message = teamsMessage();
    delete message.from;
    expect(teamsChannelFacets(message).automation).toBe("automated");
  });

  it("treats a long parent as a message rather than a chat", () => {
    const message = teamsMessage({
      body: { contentType: "html", content: `<p>${"a".repeat(1001)}</p>` },
    });
    expect(teamsChannelFacets(message).format).toBe("message");
  });

  it("measures length on the stripped text, not the raw HTML", () => {
    const message = teamsMessage({
      body: {
        contentType: "html",
        content: `<div style="${"x".repeat(2000)}">short</div>`,
      },
    });
    expect(teamsChannelFacets(message).format).toBe("chat");
  });
});

describe("teamsDmFacets", () => {
  it("classifies a human conversation as a direct human chat", () => {
    expect(teamsDmFacets([teamsMessage(), teamsMessage()])).toEqual({
      format: "chat",
      automation: "human",
      reach: "direct",
    });
  });

  it("classifies an all-application conversation as automated", () => {
    expect(teamsDmFacets([appMessage(), appMessage()]).automation).toBe(
      "automated"
    );
  });

  it("stays human when even one message is human-shaped", () => {
    expect(
      teamsDmFacets([appMessage(), teamsMessage(), appMessage()]).automation
    ).toBe("human");
  });

  it("falls open to human for an empty batch", () => {
    expect(teamsDmFacets([]).automation).toBe("human");
  });

  it("ignores system event messages when judging automation", () => {
    const system = teamsMessage({ messageType: "systemEventMessage" });
    delete system.from;
    expect(teamsDmFacets([system]).automation).toBe("human");
  });
});

describe("transform facet stamping", () => {
  it("stamps list-reach facets on a channel thread", () => {
    const link = transformChannelThread(
      teamsMessage(),
      [],
      "team1",
      "channel1",
      true
    );
    expect(link.facets).toEqual({
      format: "chat",
      automation: "human",
      reach: "list",
    });
  });

  it("stamps direct-reach facets on a DM thread", () => {
    const link = transformDmThread([teamsMessage()], "chat1", [], true);
    expect(link.facets).toEqual({
      format: "chat",
      automation: "human",
      reach: "direct",
    });
  });

  it("stamps fail-open facets on an empty DM chat", () => {
    const link = transformDmThread([], "chat1", [], true);
    expect(link.facets).toEqual({
      format: "chat",
      automation: "human",
      reach: "direct",
    });
  });

  it("judges a DM batch as a whole, not just the first message", () => {
    const link = transformDmThread(
      [appMessage(), teamsMessage()],
      "chat1",
      [],
      true
    );
    expect(link.facets?.automation).toBe("human");
  });
});
