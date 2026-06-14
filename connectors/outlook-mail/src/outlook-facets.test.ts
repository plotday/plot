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
});
