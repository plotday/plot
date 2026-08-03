import { describe, expect, it } from "vitest";
import { outlookSignals } from "./outlook-facets";
import type { GraphMessage } from "./graph-mail-api";

const m = (over: Partial<GraphMessage>): GraphMessage => ({
  id: "1",
  subject: "Hi",
  from: { emailAddress: { address: "ann@x.com" } },
  toRecipients: [{ emailAddress: { address: "me@y.com" } }],
  ccRecipients: [],
  ...over,
});

describe("outlookSignals", () => {
  it("captures a List-Id header, marking the message as list mail", () => {
    // Previously asserted format: "reading", automation: "automated", reach:
    // "list" via outlookFacets/classifyEmail. The automated/list verdict came
    // from this header; the reading/notification split came from body
    // length, which is now classifier logic covered by the platform's own
    // facet-derivation tests, not this file.
    const s = outlookSignals([{ name: "List-Id", value: "<news.example.com>" }], m({}));
    expect(s.listId).toBe("<news.example.com>");
  });

  it("marks a message as a reply when In-Reply-To is present", () => {
    // Previously asserted format: "message", automation: "human", reach:
    // "direct". The human/direct verdict is classifier logic over the
    // absence of list/precedence headers and the recipient count (covered
    // elsewhere on the platform side); the reply signal itself is what this
    // connector is responsible for extracting.
    const s = outlookSignals([{ name: "In-Reply-To", value: "<a@b>" }], m({ subject: "Re: Hi" }));
    expect(s.isReply).toBe(true);
  });

  it("emits the provider's own inference classification verbatim", () => {
    // Previously asserted automation: "automated", format: "notification" for
    // a short Focused-Inbox "Other" message. The Focused/Other bucket used to
    // be mapped onto a Gmail category locally; that mapping is now the
    // platform's decision, so the connector just reports the provider's own
    // bucket name verbatim.
    const s = outlookSignals(
      null,
      m({
        inferenceClassification: "other",
        from: { emailAddress: { address: "noreply@svc.com" } },
      })
    );
    expect(s.providerCategories).toEqual(["other"]);
  });

  it("null headers degrade gracefully — header-driven signals stay null", () => {
    const s = outlookSignals(null, m({}));
    expect(s.listId).toBeNull();
    expect(s.listUnsubscribe).toBeNull();
    expect(s.precedence).toBeNull();
    expect(s.isReply).toBe(false);
  });

  it("captures the trusted EOP Authentication-Results header verbatim", () => {
    // Previously exercised CTA extraction from an HTML body link alongside
    // trusted-EOP selection; CTA extraction moved server-side (the platform
    // now derives it from signals), so only the authserv-id selection —
    // connector-only knowledge — remains here. Also coverage that the
    // tightened authserv-id suffix match still accepts a real EOP sub-domain
    // like bl0pr01.prod.protection.outlook.com.
    const headers = [
      {
        name: "Authentication-Results",
        value:
          "bl0pr01.prod.protection.outlook.com; spf=pass smtp.mailfrom=contoso.com; dkim=pass header.d=contoso.com; dmarc=pass header.from=contoso.com",
      },
    ];
    const message = m({
      from: { emailAddress: { address: "hello@contoso.com", name: "Contoso" } },
      subject: "Confirm your account",
    });
    const s = outlookSignals(headers, message);
    expect(s.authResults).toBe(headers[0].value);
  });

  it("rejects a spoofed authserv-id that merely contains protection.outlook.com", () => {
    // evil-protection.outlook.com.attacker.com should NOT match after the tightening
    const headers = [
      {
        name: "Authentication-Results",
        value: "evil-protection.outlook.com.attacker.com; dmarc=pass header.from=victim.com",
      },
    ];
    const message = m({
      from: { emailAddress: { address: "no-reply@victim.com", name: "Victim" } },
    });
    const s = outlookSignals(headers, message);
    expect(s.authResults).toBeNull();
  });

  it("emits To and Cc counts separately", () => {
    const s = outlookSignals(
      null,
      m({
        toRecipients: [{ emailAddress: { address: "a@x.com" } }, { emailAddress: { address: "b@x.com" } }],
        ccRecipients: [{ emailAddress: { address: "c@x.com" } }],
      })
    );
    expect(s.toCount).toBe(2);
    expect(s.ccCount).toBe(1);
  });

  it("reports a flagged message as a FLAGGED provider flag", () => {
    const s = outlookSignals(null, m({ flag: { flagStatus: "flagged" } }));
    expect(s.providerFlags).toEqual(["FLAGGED"]);
  });

  it("reports no provider flags for an unflagged message", () => {
    const s = outlookSignals(null, m({}));
    expect(s.providerFlags).toEqual([]);
  });
});
