import { describe, expect, it } from "vitest";
import { gmailFacets } from "./gmail-facets";
import type { GmailMessage } from "./gmail-api";

function msg(opts: {
  headers: Array<[string, string]>;
  labelIds?: string[];
  body?: string;
}): GmailMessage {
  return {
    id: "m1",
    threadId: "t1",
    labelIds: opts.labelIds ?? [],
    snippet: "",
    historyId: "1",
    internalDate: "1700000000000",
    sizeEstimate: 0,
    payload: {
      mimeType: "text/plain",
      headers: opts.headers.map(([name, value]) => ({ name, value })),
      body: opts.body !== undefined ? { size: opts.body.length } : undefined,
    },
  };
}

describe("gmailFacets", () => {
  it("classifies a newsletter as reading/automated/list", () => {
    const f = gmailFacets(
      msg({
        headers: [
          ["From", "news@substack.com"],
          ["To", "me@x.com"],
          ["Subject", "The Weekly Digest"],
          ["List-Id", "<news.substack.com>"],
          ["List-Unsubscribe", "<mailto:u@substack.com>"],
        ],
      }),
      "a".repeat(4000)
    );
    expect(f).toEqual({ format: "reading", automation: "automated", reach: "list" });
  });

  it("classifies a personal 1:1 email as message/human/direct", () => {
    const f = gmailFacets(
      msg({ headers: [["From", "jane@friends.com"], ["To", "me@x.com"], ["Subject", "Lunch?"]] }),
      "a".repeat(500)
    );
    expect(f).toEqual({ format: "message", automation: "human", reach: "direct" });
  });

  it("classifies a GitHub notification", () => {
    const f = gmailFacets(
      msg({
        headers: [["From", "notifications@github.com"], ["To", "me@x.com"], ["Subject", "[repo] PR merged"]],
        labelIds: ["CATEGORY_UPDATES"],
      }),
      "short"
    );
    expect(f.format).toBe("notification");
    expect(f.automation).toBe("automated");
  });
});
