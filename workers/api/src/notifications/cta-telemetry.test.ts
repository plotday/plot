import { describe, expect, it } from "vitest";

import { ctaPushProperties } from "./cta-telemetry";

describe("ctaPushProperties", () => {
  it("captures kind, facets, and sender domain for a genuine OTP", () => {
    expect(
      ctaPushProperties(
        "otp",
        { format: "notification", reach: "direct", automation: "automated" },
        "no-reply@acme.com",
      ),
    ).toEqual({
      cta_kind: "otp",
      facet_format: "notification",
      facet_reach: "direct",
      facet_automation: "automated",
      sender_domain: "acme.com",
      likely_false_positive: false,
    });
  });

  it("flags a list-reach CTA as a likely residual false positive", () => {
    // After the extraction fix this should never occur; if it does, it means a
    // bulk/promo CTA slipped through — surface it so we can tune the detector.
    const props = ctaPushProperties(
      "otp",
      { format: "promotion", reach: "list", automation: "automated" },
      "sale@deals.example.com",
    );
    expect(props.likely_false_positive).toBe(true);
    expect(props.sender_domain).toBe("deals.example.com");
  });

  it("flags a promotion-format CTA as a likely false positive even when reach is direct", () => {
    expect(
      ctaPushProperties("confirm", { format: "promotion", reach: "direct", automation: "automated" }, "x@y.com")
        .likely_false_positive,
    ).toBe(true);
  });

  it("tolerates null facets and null sender", () => {
    expect(ctaPushProperties("otp", null, null)).toEqual({
      cta_kind: "otp",
      facet_format: null,
      facet_reach: null,
      facet_automation: null,
      sender_domain: null,
      likely_false_positive: false,
    });
  });
});
