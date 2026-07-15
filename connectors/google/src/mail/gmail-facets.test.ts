import { describe, expect, it } from "vitest";
import { gmailFacets } from "./gmail-facets";
import type { GmailMessage, GmailMessagePart } from "./gmail-api";

/** Encode a UTF-8 string as base64url (matches Gmail's wire format). */
function b64url(s: string): string {
  return Buffer.from(s, "utf8").toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

function msg(opts: {
  headers: Array<[string, string]>;
  labelIds?: string[];
  htmlBody?: string;
}): GmailMessage {
  const topHeaders = opts.headers.map(([name, value]) => ({ name, value }));

  let payload: GmailMessagePart;
  if (opts.htmlBody !== undefined) {
    // multipart/alternative with an html part so getMessageHtml (via findPartContent) can find it
    payload = {
      mimeType: "multipart/alternative",
      headers: topHeaders,
      parts: [
        {
          mimeType: "text/plain",
          headers: [],
          body: { size: 0, data: b64url("") },
        },
        {
          mimeType: "text/html",
          headers: [],
          body: { size: opts.htmlBody.length, data: b64url(opts.htmlBody) },
        },
      ],
    };
  } else {
    payload = {
      mimeType: "text/plain",
      headers: topHeaders,
    };
  }

  return {
    id: "m1",
    threadId: "t1",
    labelIds: opts.labelIds ?? [],
    snippet: "",
    historyId: "1",
    internalDate: "1700000000000",
    sizeEstimate: 0,
    payload,
  };
}

describe("gmailFacets", () => {
  it("classifies a newsletter as reading/automated/list", () => {
    const { facets } = gmailFacets(
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
    expect(facets).toEqual({ format: "reading", automation: "automated", reach: "list" });
  });

  it("classifies a personal 1:1 email as message/human/direct", () => {
    const { facets } = gmailFacets(
      msg({ headers: [["From", "jane@friends.com"], ["To", "me@x.com"], ["Subject", "Lunch?"]] }),
      "a".repeat(500)
    );
    expect(facets).toEqual({ format: "message", automation: "human", reach: "direct" });
  });

  it("classifies a GitHub notification", () => {
    const { facets } = gmailFacets(
      msg({
        headers: [["From", "notifications@github.com"], ["To", "me@x.com"], ["Subject", "[repo] PR merged"]],
        labelIds: ["CATEGORY_UPDATES"],
      }),
      "short"
    );
    expect(facets.format).toBe("notification");
    expect(facets.automation).toBe("automated");
  });

  it("extracts a confirm cta from an HTML body link with trusted DMARC", () => {
    // This test exercises getMessageHtml, which calls findPartContent (already decoded).
    // With the double-decode bug (decodeBase64Url(findPartContent(...))), the HTML
    // would be re-decoded as base64url and produce garbage, so extractLinkCandidates
    // would find no links and cta would be null. Fix: getMessageHtml returns
    // findPartContent directly without re-decoding.
    const message = msg({
      headers: [
        ["From", "Acme <hello@acme.com>"],
        ["To", "user@example.com"],
        ["Subject", "Confirm your email"],
        [
          "Authentication-Results",
          "mx.google.com; spf=pass smtp.mailfrom=acme.com; dkim=pass header.d=acme.com; dmarc=pass header.from=acme.com",
        ],
      ],
      htmlBody: `<p>Welcome to Acme</p><a href="https://acme.com/confirm?t=abc123">Confirm your email</a>`,
    });
    const { facets, cta } = gmailFacets(message, "Welcome to Acme Confirm your email");
    expect(cta).toEqual({
      kind: "confirm",
      service: "Acme",
      code: null,
      url: "https://acme.com/confirm?t=abc123",
    });
    // gmailFacets returns raw classifyEmail output; the caller merges cta.kind into
    // facets.format (see gmail.ts: `cta ? { ...facets, format: cta.kind } : facets`).
    // Here we just confirm cta is present and facets is non-null.
    expect(facets).not.toBeNull();
  });
});
