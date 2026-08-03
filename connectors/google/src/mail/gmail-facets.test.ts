import { describe, expect, it } from "vitest";
import { gmailSignals } from "./gmail-facets";
import type { GmailMessage } from "./gmail-api";

function msg(opts: { headers: Array<[string, string]>; labelIds?: string[] }): GmailMessage {
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
    },
  };
}

describe("gmailSignals", () => {
  it("extracts List-Id and List-Unsubscribe from a newsletter", () => {
    // Previously asserted format: "reading", automation: "automated", reach:
    // "list" via classifyEmail. The automated/list verdict came from these two
    // headers; the reading/notification split came from body length, which is
    // now classifier logic covered by the platform's own facet-derivation
    // tests, not this file.
    const message = msg({
      headers: [
        ["From", "news@substack.com"],
        ["To", "me@x.com"],
        ["Subject", "The Weekly Digest"],
        ["List-Id", "<news.substack.com>"],
        ["List-Unsubscribe", "<mailto:u@substack.com>"],
      ],
    });
    const s = gmailSignals(message);
    expect(s.listId).toBe("<news.substack.com>");
    expect(s.listUnsubscribe).toBe("<mailto:u@substack.com>");
  });

  it("extracts no automation signals for a personal 1:1 email", () => {
    // Previously asserted format: "message", automation: "human", reach:
    // "direct" via classifyEmail. The human verdict came from the absence of
    // list/precedence/auto-submitted signals (now classifier logic, covered
    // elsewhere on the platform side); the direct verdict came from a single
    // To recipient (toCount), covered here plus by the toCount/ccCount case
    // below.
    const message = msg({
      headers: [
        ["From", "jane@friends.com"],
        ["To", "me@x.com"],
        ["Subject", "Lunch?"],
      ],
    });
    const s = gmailSignals(message);
    expect(s.listId).toBeNull();
    expect(s.precedence).toBeNull();
    expect(s.autoSubmitted).toBeNull();
    expect(s.fromAddress).toBe("jane@friends.com");
    expect(s.toCount).toBe(1);
  });

  it("extracts CATEGORY_UPDATES as a provider category", () => {
    // Previously asserted format: "notification", automation: "automated" for
    // a GitHub notification. The automated verdict is classifier logic over
    // the sender/labels (covered elsewhere on the platform side); the label
    // itself is the signal this connector is responsible for extracting.
    const message = msg({
      headers: [
        ["From", "notifications@github.com"],
        ["To", "me@x.com"],
        ["Subject", "[repo] PR merged"],
      ],
      labelIds: ["CATEGORY_UPDATES"],
    });
    const s = gmailSignals(message);
    expect(s.providerCategories).toEqual(["CATEGORY_UPDATES"]);
  });

  it("selects the Authentication-Results header added by Google's receiving MTA", () => {
    // Previously exercised CTA extraction from an HTML body link alongside
    // trusted-DMARC selection; CTA extraction moved server-side (the platform
    // now derives it from signals), so only the authserv-id selection —
    // connector-only knowledge — remains here.
    const authResults =
      "mx.google.com; spf=pass smtp.mailfrom=acme.com; dkim=pass header.d=acme.com; dmarc=pass header.from=acme.com";
    const message = msg({
      headers: [
        ["From", "Acme <hello@acme.com>"],
        ["To", "user@example.com"],
        ["Subject", "Confirm your email"],
        ["Authentication-Results", authResults],
      ],
    });
    const s = gmailSignals(message);
    expect(s.authResults).toBe(authResults);
  });

  it("ignores an Authentication-Results header from an untrusted authserv-id", () => {
    const message = msg({
      headers: [
        ["From", "Acme <hello@acme.com>"],
        ["To", "user@example.com"],
        ["Subject", "Confirm your email"],
        ["Authentication-Results", "spf1.example.net; spf=pass smtp.mailfrom=acme.com"],
      ],
    });
    const s = gmailSignals(message);
    expect(s.authResults).toBeNull();
  });

  it("emits To and Cc counts separately", () => {
    const message = msg({
      headers: [
        ["From", "a@example.com"],
        ["To", "a@example.com, b@example.com"],
        ["Cc", "c@example.com"],
      ],
    });
    const s = gmailSignals(message);
    expect(s.toCount).toBe(2);
    expect(s.ccCount).toBe(1);
  });
});
