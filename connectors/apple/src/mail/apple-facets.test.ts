import { describe, expect, it } from "vitest";
import { appleMailSignals } from "./apple-facets";
import type { MailMessage } from "./transform";

function msg(over: Partial<MailMessage>): MailMessage {
  return {
    uid: 1,
    flags: [],
    mailbox: "INBOX",
    from: [{ address: "ann@x.com" }],
    to: [{ address: "me@icloud.com" }],
    ...over,
  };
}

describe("appleMailSignals", () => {
  it("extracts a List-Id header from a newsletter", () => {
    // Previously asserted automation: "automated", reach: "list", format:
    // "reading" via classifyEmail. The automated/list verdict came from this
    // header; the reading/notification split came from body length, which is
    // now classifier logic covered platform-side, not this file.
    const s = appleMailSignals(msg({ listId: "<news.example.com>" }));
    expect(s.listId).toBe("<news.example.com>");
  });

  it("marks a message as a reply when In-Reply-To is present", () => {
    // Previously asserted automation: "human", reach: "direct", format:
    // "message" for a plain human reply. The human/direct verdict is
    // classifier logic over the absence of list/precedence headers and the
    // recipient count (covered platform-side); the reply signal itself is
    // what this connector is responsible for extracting.
    const s = appleMailSignals(msg({ inReplyTo: "<a@b>", subject: "Re: Hi" }));
    expect(s.isReply).toBe(true);
  });

  it("extracts a no-reply sender's address verbatim (lowercased)", () => {
    // Previously asserted automation: "automated", format: "notification"
    // for a short automated mail from a no-reply sender. That verdict came
    // from classifier logic over the sender-address pattern and body
    // length (now platform-side); the address extraction itself is what
    // this connector is responsible for.
    const s = appleMailSignals(msg({ from: [{ address: "No-Reply@SVC.com" }] }));
    expect(s.fromAddress).toBe("no-reply@svc.com");
  });

  it("extracts no automation signals for a message with no facet-signal headers", () => {
    // Previously asserted automation: "human", reach: "direct" for a message
    // with none of the automation-indicating headers set. Same classifier
    // logic as above, covered platform-side.
    const s = appleMailSignals(msg({}));
    expect(s.listId).toBeNull();
    expect(s.precedence).toBeNull();
    expect(s.autoSubmitted).toBeNull();
    expect(s.isReply).toBe(false);
  });

  it("captures a trusted iCloud Authentication-Results header verbatim", () => {
    // Previously exercised CTA extraction from an HTML body link alongside
    // trusted-DMARC selection; CTA extraction moved server-side (the
    // platform now derives it from signals), so only the authserv-id
    // selection — connector-only knowledge — remains here.
    const authResults = "icloud.com; spf=pass smtp.mailfrom=contoso.com; dkim=pass header.d=contoso.com; dmarc=pass header.from=contoso.com";
    const message = msg({
      from: [{ address: "hello@contoso.com", name: "Contoso" }],
      authenticationResults: [authResults],
    });
    const s = appleMailSignals(message);
    expect(s.authResults).toBe(authResults);
  });

  it("accepts a trusted iCloud auth-results reported by a specific mail-exchanger subdomain", () => {
    // Coverage that the suffix match (authservId.endsWith(".icloud.com")),
    // not just an exact "icloud.com" match, still accepts a real
    // mail-exchanger sub-host like mx05.mail.icloud.com.
    const authResults = "mx05.mail.icloud.com; dmarc=pass header.from=contoso.com";
    const message = msg({
      from: [{ address: "hello@contoso.com", name: "Contoso" }],
      authenticationResults: [authResults],
    });
    const s = appleMailSignals(message);
    expect(s.authResults).toBe(authResults);
  });

  it("finds the DMARC verdict when iCloud splits SPF/DKIM/DMARC/BIMI across separate Authentication-Results headers", () => {
    // VERIFIED against a real "Welcome to iCloud Mail" message from
    // noreply@email.apple.com (2026-07-22): iCloud stamps FOUR separate
    // Authentication-Results headers, one per mechanism, each on its own
    // *.icloud.com sub-host — unlike Gmail/Outlook, which stamp one combined
    // header per hop. The BIMI one (which carries no dmarc= verdict at all)
    // appears FIRST on the wire, so a naive "first header whose authserv-id
    // ends with .icloud.com" pick would return it and the DMARC regex would
    // never match — this test pins that the correct (dmarc=-bearing) header
    // is found regardless of header order.
    const dmarcResult = "dmarc.icloud.com; dmarc=pass header.from=contoso.com";
    const message = msg({
      from: [{ address: "hello@contoso.com", name: "Contoso" }],
      authenticationResults: [
        "bimi.icloud.com; bimi=pass header.d=contoso.com header.selector=default policy.authority=pass",
        dmarcResult,
        "dkim-verifier.icloud.com; dkim=pass header.d=contoso.com header.i=@contoso.com",
        "spf.icloud.com; spf=pass smtp.mailfrom=contoso.com",
      ],
    });
    const s = appleMailSignals(message);
    expect(s.authResults).toBe(dmarcResult);
  });

  it("rejects a spoofed authserv-id that merely contains icloud.com", () => {
    // evil-icloud.com.attacker.com should NOT match after the suffix tightening.
    const message = msg({
      from: [{ address: "no-reply@victim.com", name: "Victim" }],
      authenticationResults: ["evil-icloud.com.attacker.com; dmarc=pass header.from=victim.com"],
    });
    const s = appleMailSignals(message);
    expect(s.authResults).toBeNull();
  });

  it("selects Importance over X-Priority, falling back to X-Priority when Importance is absent", () => {
    const withImportance = appleMailSignals(msg({ importance: "high", xPriority: "1" }));
    expect(withImportance.importance).toBe("high");
    const withXPriorityOnly = appleMailSignals(msg({ xPriority: "1" }));
    expect(withXPriorityOnly.importance).toBe("1");
  });

  it("emits To and Cc counts separately", () => {
    const s = appleMailSignals(
      msg({
        to: [{ address: "me@icloud.com" }, { address: "friend@x.com" }],
        cc: [{ address: "cc@x.com" }],
      })
    );
    expect(s.toCount).toBe(2);
    expect(s.ccCount).toBe(1);
  });

  it("always emits empty provider categories and flags — IMAP has no equivalent", () => {
    const s = appleMailSignals(msg({}));
    expect(s.providerCategories).toEqual([]);
    expect(s.providerFlags).toEqual([]);
  });
});
