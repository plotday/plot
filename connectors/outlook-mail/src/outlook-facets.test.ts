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
    const f = outlookFacets(
      [{ name: "List-Id", value: "<news.example.com>" }],
      m({}),
      "x".repeat(2000)
    );
    expect(f.automation).toBe("automated");
    expect(f.reach).toBe("list");
    expect(f.format).toBe("reading");
  });

  it("plain human reply → human/direct/message", () => {
    const f = outlookFacets(
      [{ name: "In-Reply-To", value: "<a@b>" }],
      m({ subject: "Re: Hi" }),
      "short"
    );
    expect(f.automation).toBe("human");
    expect(f.reach).toBe("direct");
    expect(f.format).toBe("message");
  });

  it("short Other-inbox automated mail → notification (no headers available)", () => {
    const f = outlookFacets(
      null,
      m({
        inferenceClassification: "other",
        from: { emailAddress: { address: "noreply@svc.com" } },
      }),
      "tiny"
    );
    expect(f.automation).toBe("automated");
    expect(f.format).toBe("notification");
  });

  it("null headers degrade gracefully", () => {
    const f = outlookFacets(null, m({}), "hello there");
    expect(f.automation).toBe("human");
    expect(f.reach).toBe("direct");
  });
});
