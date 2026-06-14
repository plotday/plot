import { describe, expect, it } from "vitest";
import { extractCta } from "./extract-cta";
import type { EmailSignals } from "./classify-email";

function signals(over: Partial<EmailSignals>): EmailSignals {
  return {
    listId: null, listUnsubscribe: null, precedence: null, autoSubmitted: null,
    returnPath: null, importance: null, fromAddress: null, recipientCount: 1,
    isReply: false, subject: null, bodyLength: 0, gmailCategories: [],
    bodyText: null, fromName: null, links: [], authResults: null,
    ...over,
  };
}

describe("extractCta — OTP", () => {
  it("extracts a keyword-anchored numeric code", () => {
    const cta = extractCta(signals({
      fromAddress: "no-reply@acme.com", fromName: "Acme",
      subject: "Your verification code",
      bodyText: "Your verification code is 482913. It expires in 10 minutes.",
    }));
    expect(cta).toEqual({ kind: "otp", service: "Acme", code: "482913", url: null });
  });
  it("extracts a grouped/alphanumeric code (Google style)", () => {
    const cta = extractCta(signals({
      fromAddress: "no-reply@google.com",
      subject: "G-557812 is your Google verification code",
      bodyText: "G-557812 is your Google verification code.",
    }));
    expect(cta?.kind).toBe("otp");
    expect(cta?.code).toBe("G-557812");
    expect(cta?.service).toBe("Google");
  });
  it("does NOT treat an order total / price as a code", () => {
    expect(extractCta(signals({
      fromAddress: "orders@shop.com",
      subject: "Order confirmation",
      bodyText: "Your order confirmation code total is $129456.",
    }))).toBeNull();
  });
  it("does NOT treat a bare 4-digit year as a code", () => {
    expect(extractCta(signals({
      bodyText: "Your verification code expires in 2026.",
    }))).toBeNull();
  });
});

describe("extractCta — confirm link", () => {
  const dmarcPass = "spf=pass; dkim=pass; dmarc=pass header.from=acme.com";
  it("extracts a confirm link when DMARC passes and anchor text is positive", () => {
    const cta = extractCta(signals({
      fromAddress: "hello@acme.com", fromName: "Acme",
      subject: "Confirm your email",
      authResults: dmarcPass,
      links: [{ text: "Confirm email", href: "https://acme.com/confirm?t=xyz" }],
    }));
    expect(cta).toEqual({ kind: "confirm", service: "Acme", code: null, url: "https://acme.com/confirm?t=xyz" });
  });
  it("SKIPS the link when DMARC does not pass", () => {
    expect(extractCta(signals({
      fromAddress: "hello@acme.com", subject: "Confirm your email",
      authResults: "spf=fail; dkim=none; dmarc=fail header.from=acme.com",
      links: [{ text: "Confirm email", href: "https://evil.example/confirm" }],
    }))).toBeNull();
  });
  it("SKIPS negative-context links (wasn't you / reset / unsubscribe)", () => {
    expect(extractCta(signals({
      fromAddress: "hello@acme.com", subject: "Security alert",
      authResults: dmarcPass,
      links: [
        { text: "This wasn't me", href: "https://acme.com/secure" },
        { text: "Reset your password", href: "https://acme.com/reset" },
        { text: "Unsubscribe", href: "https://acme.com/u" },
      ],
    }))).toBeNull();
  });
  it("SKIPS when two distinct confirm-verb links conflict", () => {
    expect(extractCta(signals({
      fromAddress: "hello@acme.com", subject: "Confirm",
      authResults: dmarcPass,
      links: [
        { text: "Confirm email", href: "https://acme.com/a" },
        { text: "Verify account", href: "https://acme.com/b" },
      ],
    }))).toBeNull();
  });
  it("prefers OTP when both a code and a confirm link are present", () => {
    const cta = extractCta(signals({
      fromAddress: "hello@acme.com", fromName: "Acme",
      subject: "Confirm your email",
      authResults: dmarcPass,
      bodyText: "Your code is 224466 or click below.",
      links: [{ text: "Confirm email", href: "https://acme.com/confirm" }],
    }));
    expect(cta?.kind).toBe("otp");
    expect(cta?.code).toBe("224466");
  });

  it("SKIPS a confirm link whose host is NOT the DMARC-verified sender domain", () => {
    expect(extractCta(signals({
      fromAddress: "hello@acme.com", subject: "Confirm your email",
      authResults: dmarcPass, // dmarc=pass header.from=acme.com
      links: [{ text: "Confirm email", href: "https://evil.example/confirm" }],
    }))).toBeNull();
  });

  it("SKIPS when dmarc=pass is for a different header.from than the sender", () => {
    expect(extractCta(signals({
      fromAddress: "hello@acme.com", subject: "Confirm your email",
      authResults: "spf=pass; dkim=pass; dmarc=pass header.from=evil.com",
      links: [{ text: "Confirm email", href: "https://evil.com/confirm" }],
    }))).toBeNull();
  });

  it("SKIPS a non-http(s) scheme link even with valid confirm text", () => {
    expect(extractCta(signals({
      fromAddress: "hello@acme.com", subject: "Confirm your email",
      authResults: dmarcPass,
      links: [{ text: "Confirm email", href: "javascript:alert(1)" }],
    }))).toBeNull();
  });

  it("SKIPS a userinfo-spoofed link (https://sender.com@evil.com/...)", () => {
    expect(extractCta(signals({
      fromAddress: "hello@acme.com", subject: "Confirm",
      authResults: dmarcPass, // header.from=acme.com
      links: [{ text: "Confirm email", href: "https://acme.com@evil.example/confirm" }],
    }))).toBeNull();
  });

  it("ALLOWS a confirm link on a subdomain of the verified sender domain", () => {
    const cta = extractCta(signals({
      fromAddress: "hello@acme.com", fromName: "Acme", subject: "Confirm your email",
      authResults: dmarcPass,
      links: [{ text: "Confirm email", href: "https://login.acme.com/confirm?t=1" }],
    }));
    expect(cta).toEqual({ kind: "confirm", service: "Acme", code: null, url: "https://login.acme.com/confirm?t=1" });
  });
});

describe("extractCta — none", () => {
  it("returns null for ordinary mail", () => {
    expect(extractCta(signals({
      fromAddress: "jane@friend.com", fromName: "Jane",
      subject: "Lunch tomorrow?", bodyText: "Want to grab lunch at noon?",
    }))).toBeNull();
  });
});
