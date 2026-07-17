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
  it("extracts a code shown on the line AFTER the keyword line", () => {
    // Many providers display the code prominently on its own line/box, below
    // the "enter the following code" sentence — the keyword and the code are
    // NOT on the same line.
    const cta = extractCta(signals({
      fromAddress: "no-reply@example.com", fromName: "Example",
      subject: "Verifying it's you",
      bodyText: "To access Example, enter the following code:\n\nFP9I0Z\n\nThis code expires soon.",
    }));
    expect(cta?.kind).toBe("otp");
    expect(cta?.code).toBe("FP9I0Z");
  });
  it("extracts an interleaved alphanumeric code (e.g. FP9I0Z) on a keyword line", () => {
    const cta = extractCta(signals({
      fromAddress: "no-reply@example.com", fromName: "Example",
      subject: "Your access code",
      bodyText: "Your access code is FP9I0Z.",
    }));
    expect(cta?.kind).toBe("otp");
    expect(cta?.code).toBe("FP9I0Z");
  });
  it("extracts a code from an HTML body where the code sits in its own block element", () => {
    // Connectors commonly pass the raw HTML note body. Block boundaries, not
    // newlines, separate the keyword sentence from the displayed code.
    const cta = extractCta(signals({
      fromAddress: "no-reply@example.com", fromName: "Example",
      subject: "Verifying it's you",
      bodyText:
        "<p>To access Example, enter the following code:</p>" +
        '<div style="font-size:32px;font-weight:bold">FP9I0Z</div>' +
        "<p>This code expires soon.</p>",
    }));
    expect(cta?.kind).toBe("otp");
    expect(cta?.code).toBe("FP9I0Z");
  });
  it("does NOT treat a number in an HTML tag attribute as a code", () => {
    // Numbers living inside tag attributes (widths, tracking ids) must never
    // surface — tag stripping removes them before scanning.
    expect(extractCta(signals({
      fromAddress: "no-reply@shop.com", fromName: "Shop",
      subject: "Your verification code",
      bodyText:
        "<p>Your verification code:</p>" +
        '<table width="480123"><tr><td>Welcome aboard!</td></tr></table>',
    }))).toBeNull();
  });
  it("does NOT treat a bare word on the line after a keyword as a code", () => {
    // The line after the keyword must contain digits to be a code — a plain
    // word (sign-off, service name) must not be picked up.
    expect(extractCta(signals({
      fromAddress: "no-reply@acme.com", fromName: "Acme",
      subject: "Your verification code",
      bodyText: "Enter the verification code below:\n\nRegards\n\nThe Acme team",
    }))).toBeNull();
  });
});

describe("extractCta — transactional OTP on mailing-list mail", () => {
  // Real transactional senders (identity/security mail) increasingly stamp
  // List-Unsubscribe on their OTP messages, which classifies them reach=list.
  // A genuine one-time code must NOT be suppressed just because of that header
  // — only promotional mail (format=promotion) is the false-positive class.
  it("extracts an OTP from a list-classified (List-Unsubscribe) transactional mail with code in subject", () => {
    const cta = extractCta(signals({
      fromAddress: "no-reply@asana.com", fromName: "Asana",
      listUnsubscribe: "<https://asana.com/unsubscribe>",
      subject: "Asana confirmation code: 412855",
      bodyText:
        "Confirm your email address\n\n" +
        "Thank you for signing up for Asana! Enter the code below in your open web browser window.\n\n" +
        "412855",
      bodyLength: 1400,
    }));
    expect(cta?.kind).toBe("otp");
    expect(cta?.code).toBe("412855");
    expect(cta?.service).toBe("Asana");
  });
  it("extracts an OTP from list-classified mail with the code only in the body", () => {
    const cta = extractCta(signals({
      fromAddress: "no-reply@service.com", fromName: "Service",
      listUnsubscribe: "<https://service.com/unsubscribe>",
      subject: "Your verification code",
      bodyText: "Your verification code is 771234. It expires in 10 minutes.",
    }));
    expect(cta?.kind).toBe("otp");
    expect(cta?.code).toBe("771234");
  });
  it("STILL suppresses a promotional (format=promotion) discount code on list mail", () => {
    // The promo false-positive class stays suppressed — promotion, not merely
    // list membership, is what disqualifies a code.
    expect(extractCta(signals({
      fromAddress: "sale@promo.com", fromName: "Promo",
      listUnsubscribe: "<https://promo.com/u>",
      subject: "50% OFF everything this weekend!",
      bodyText: "Use code 8558 at checkout for an extra discount.",
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

describe("extractCta — promotional false positives", () => {
  // Real samples mined from prod (martha.braun@gmail.com): bulk marketing mail
  // that the old detector mis-read as an OTP because a 4-8 digit number sat near
  // the bare word "code". A genuine one-time code is transactional and direct —
  // never a bulk mailing-list blast — so reach=list / promotion must suppress it.
  it("does NOT treat a bulk-list promo with a 'code' number as an OTP", () => {
    expect(extractCta(signals({
      fromAddress: "sale@l904gw.fi86.fdske.com", fromName: "Ashley Rose Reeves",
      listUnsubscribe: "<https://l904gw.fi86.fdske.com/u>",
      subject: "Hydrojugs are 50% OFF!! 💥",
      bodyText: "Summer blowout! Use code 8558 at checkout for an extra discount.",
    }))).toBeNull();
  });
  it("does NOT treat a Gmail CATEGORY_PROMOTIONS mail (reach=direct) as an OTP", () => {
    expect(extractCta(signals({
      fromAddress: "deals@modlily.com", fromName: "Modlily",
      gmailCategories: ["CATEGORY_PROMOTIONS"],
      subject: "Fresh Dress Arrivals Just For You 🎁",
      bodyText: "Shop now with code 4070 for free shipping.",
    }))).toBeNull();
  });
  it("does NOT treat a promo-context 'promo code' line as an OTP", () => {
    expect(extractCta(signals({
      fromAddress: "hello@store.com", fromName: "Store",
      subject: "20% off everything",
      bodyText: "Enter promo code 5678 for 20% off your order.",
    }))).toBeNull();
  });
  it("does NOT treat an all-same-digit placeholder as an OTP", () => {
    expect(extractCta(signals({
      fromAddress: "no-reply@penningtons.com", fromName: "Penningtons",
      subject: "Ends Tonight: 40% Off",
      bodyText: "Your code: 000000. Shop the sale now!",
    }))).toBeNull();
  });
  // Real samples (martha.braun@gmail.com): direct, automated transactional mail
  // — NOT list/promotion, so the reach gate doesn't catch them — where the old
  // detector spliced a digit fragment out of a tracking-link token sitting on a
  // line that happened to carry a code keyword. A genuine OTP is a small,
  // STANDALONE code, never a slice of a longer URL/UUID/identifier.
  it("does NOT splice a digit fragment out of a tracking-link token (Reclaim)", () => {
    // thread CcRuoq3tNqLxdMEYHVYLh — "Weekly Report" report email. The fragment
    // 39378156 lived inside …f76e-39378156-bc8f… on a line with "Sign in".
    expect(extractCta(signals({
      fromAddress: "no-reply@reclaim.ai", fromName: "Reclaim.ai",
      subject: "🎉 Weekly Report at Reclaim: Jun 20 - 26",
      bodyText:
        "Sign in to view your stats: https://app.reclaim.ai/i/CL0/stats/0100019f0401f76e-39378156-bc8f-4558-a478-526a2151ab73-0",
    }))).toBeNull();
  });
  it("does NOT treat an order-number id or a URL fragment as an OTP (Walmart)", () => {
    // thread CcRquZiM1Uy9ri8GsPk7r — "Thank you for shopping with us!". The
    // 15-digit order number must not be chopped to an 8-digit code, and the
    // fragment 750993 inside a clickTracker URL must not surface either.
    expect(extractCta(signals({
      fromAddress: "no-reply@walmart.ca", fromName: "Walmart Canada",
      subject: "Thank you for shopping with us!",
      bodyText:
        "Thank you for shopping with us! Order number: 600000097650390.\n" +
        "Access your account here: https://w-mt.ca/g/rptrcks/clickTracker?redirectTo=msnpt+750993/dFeijEb7W5",
    }))).toBeNull();
  });
  it("does NOT extract a confirm CTA from a bulk-list mailing", () => {
    const dmarcPass = "spf=pass; dkim=pass; dmarc=pass header.from=shop.com";
    expect(extractCta(signals({
      fromAddress: "news@shop.com", fromName: "Shop",
      listUnsubscribe: "<https://shop.com/u>",
      subject: "Confirm you still want our deals",
      authResults: dmarcPass,
      links: [{ text: "Confirm preferences", href: "https://shop.com/confirm" }],
    }))).toBeNull();
  });
  it("STILL extracts a genuine OTP from a direct transactional mail", () => {
    const cta = extractCta(signals({
      fromAddress: "no-reply@acme.com", fromName: "Acme",
      subject: "Your verification code",
      bodyText: "Your verification code is 482913. It expires in 10 minutes.",
    }));
    expect(cta).toEqual({ kind: "otp", service: "Acme", code: "482913", url: null });
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
