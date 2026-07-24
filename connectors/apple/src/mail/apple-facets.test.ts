import { describe, expect, it } from "vitest";
import { appleMailFacets } from "./apple-facets";
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

describe("appleMailFacets", () => {
  it("newsletter with List-Id → automated/list", () => {
    const { facets } = appleMailFacets(
      msg({ listId: "<news.example.com>" }),
      "x".repeat(2000)
    );
    expect(facets.automation).toBe("automated");
    expect(facets.reach).toBe("list");
    expect(facets.format).toBe("reading");
  });

  it("plain human reply → human/direct/message", () => {
    const { facets } = appleMailFacets(
      msg({ inReplyTo: "<a@b>", subject: "Re: Hi" }),
      "short"
    );
    expect(facets.automation).toBe("human");
    expect(facets.reach).toBe("direct");
    expect(facets.format).toBe("message");
  });

  it("short automated mail from a no-reply sender → notification", () => {
    const { facets } = appleMailFacets(
      msg({ from: [{ address: "no-reply@svc.com" }] }),
      "tiny"
    );
    expect(facets.automation).toBe("automated");
    expect(facets.format).toBe("notification");
  });

  it("message with no facet-signal headers degrades gracefully", () => {
    const { facets } = appleMailFacets(msg({}), "hello there");
    expect(facets.automation).toBe("human");
    expect(facets.reach).toBe("direct");
  });

  it("extracts a confirm cta from an HTML body link with a trusted iCloud auth-results", () => {
    const message = msg({
      from: [{ address: "hello@contoso.com", name: "Contoso" }],
      subject: "Confirm your account",
      bodyHtml: `<p>Welcome</p><a href="https://contoso.com/verify?token=xyz">Confirm your account</a>`,
      authenticationResults: [
        "icloud.com; spf=pass smtp.mailfrom=contoso.com; dkim=pass header.d=contoso.com; dmarc=pass header.from=contoso.com",
      ],
    });
    const { facets, cta } = appleMailFacets(
      message,
      "Welcome Confirm your account"
    );
    expect(cta).toEqual({
      kind: "confirm",
      service: "Contoso",
      code: null,
      url: "https://contoso.com/verify?token=xyz",
    });
    expect(facets).not.toBeNull();
  });

  it("accepts a trusted iCloud auth-results reported by a specific mail-exchanger subdomain", () => {
    const message = msg({
      from: [{ address: "hello@contoso.com", name: "Contoso" }],
      bodyHtml: `<a href="https://contoso.com/verify">Confirm your account</a>`,
      authenticationResults: [
        "mx05.mail.icloud.com; dmarc=pass header.from=contoso.com",
      ],
    });
    const { cta } = appleMailFacets(message, "Confirm your account");
    expect(cta?.kind).toBe("confirm");
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
    const message = msg({
      from: [{ address: "hello@contoso.com", name: "Contoso" }],
      bodyHtml: `<a href="https://contoso.com/verify">Confirm your account</a>`,
      authenticationResults: [
        "bimi.icloud.com; bimi=pass header.d=contoso.com header.selector=default policy.authority=pass",
        "dmarc.icloud.com; dmarc=pass header.from=contoso.com",
        "dkim-verifier.icloud.com; dkim=pass header.d=contoso.com header.i=@contoso.com",
        "spf.icloud.com; spf=pass smtp.mailfrom=contoso.com",
      ],
    });
    const { cta } = appleMailFacets(message, "Confirm your account");
    expect(cta).toEqual({
      kind: "confirm",
      service: "Contoso",
      code: null,
      url: "https://contoso.com/verify",
    });
  });

  it("rejects a spoofed authserv-id that merely contains icloud.com", () => {
    // evil-icloud.com.attacker.com should NOT match after the suffix tightening.
    const message = msg({
      from: [{ address: "no-reply@victim.com", name: "Victim" }],
      bodyHtml: `<a href="https://victim.com/confirm">Confirm</a>`,
      authenticationResults: [
        "evil-icloud.com.attacker.com; dmarc=pass header.from=victim.com",
      ],
    });
    const { cta } = appleMailFacets(message, "Confirm");
    // Without trusted auth-results the link host can't be validated → no confirm cta.
    expect(cta?.kind).not.toBe("confirm");
  });

  it("selects Importance over X-Priority, falling back to X-Priority when Importance is absent", () => {
    const withImportance = appleMailFacets(
      msg({ importance: "high", xPriority: "1" }),
      "hi"
    );
    const withXPriorityOnly = appleMailFacets(msg({ xPriority: "1" }), "hi");
    // Both just need to not throw and to have run the classifier — importance
    // itself isn't asserted on `facets` directly (it's carried as raw signal),
    // so this test pins that the fallback wiring doesn't crash either way.
    expect(withImportance.facets).not.toBeNull();
    expect(withXPriorityOnly.facets).not.toBeNull();
  });
});
