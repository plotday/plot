import { describe, expect, it } from "vitest";
import { outlookFacets } from "./outlook-facets";
import type { GraphMessage } from "./graph-mail-api";

const m = (over: Partial<GraphMessage>): GraphMessage => ({
  id: "1",
  subject: "Hi",
  from: { emailAddress: { address: "ann@x.com" } },
  toRecipients: [{ emailAddress: { address: "me@y.com" } }],
  ccRecipients: [],
  ...over,
});

describe("outlookFacets", () => {
  it("newsletter with List-Id → automated/list", () => {
    const { facets } = outlookFacets(
      [{ name: "List-Id", value: "<news.example.com>" }],
      m({}),
      "x".repeat(2000)
    );
    expect(facets.automation).toBe("automated");
    expect(facets.reach).toBe("list");
    expect(facets.format).toBe("reading");
  });

  it("plain human reply → human/direct/message", () => {
    const { facets } = outlookFacets(
      [{ name: "In-Reply-To", value: "<a@b>" }],
      m({ subject: "Re: Hi" }),
      "short"
    );
    expect(facets.automation).toBe("human");
    expect(facets.reach).toBe("direct");
    expect(facets.format).toBe("message");
  });

  it("short Other-inbox automated mail → notification (no headers available)", () => {
    const { facets } = outlookFacets(
      null,
      m({
        inferenceClassification: "other",
        from: { emailAddress: { address: "noreply@svc.com" } },
      }),
      "tiny"
    );
    expect(facets.automation).toBe("automated");
    expect(facets.format).toBe("notification");
  });

  it("null headers degrade gracefully", () => {
    const { facets } = outlookFacets(null, m({}), "hello there");
    expect(facets.automation).toBe("human");
    expect(facets.reach).toBe("direct");
  });

  it("extracts a confirm cta from an HTML body link with trusted EOP auth-results", () => {
    // Outlook has no decode bug (body.content is already a plain string), so this
    // is coverage-only: verifies the full outlookFacets path (HTML link extraction +
    // DMARC trust) works end-to-end and that the tightened authserv-id suffix match
    // still accepts a real EOP sub-domain like bl0pr01.prod.protection.outlook.com.
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
      body: {
        contentType: "html",
        content: `<p>Welcome</p><a href="https://contoso.com/verify?token=xyz">Confirm your account</a>`,
      },
    });
    const { facets, cta } = outlookFacets(headers, message, "Welcome Confirm your account");
    expect(cta).toEqual({
      kind: "confirm",
      service: "Contoso",
      code: null,
      url: "https://contoso.com/verify?token=xyz",
    });
    // outlookFacets returns raw classifyEmail output; the caller merges cta.kind into
    // facets.format (see outlook-mail.ts: `cta ? { ...facets, format: cta.kind } : facets`).
    expect(facets).not.toBeNull();
  });

  it("rejects a spoofed authserv-id that merely contains protection.outlook.com", () => {
    // evil-protection.outlook.com.attacker.com should NOT match after the tightening
    const headers = [
      {
        name: "Authentication-Results",
        value:
          "evil-protection.outlook.com.attacker.com; dmarc=pass header.from=victim.com",
      },
    ];
    const message = m({
      from: { emailAddress: { address: "no-reply@victim.com", name: "Victim" } },
      body: {
        contentType: "html",
        content: `<a href="https://victim.com/confirm">Confirm</a>`,
      },
    });
    const { cta } = outlookFacets(headers, message, "Confirm");
    // Without trusted auth-results the link host can't be validated → no confirm cta
    expect(cta?.kind).not.toBe("confirm");
  });
});
