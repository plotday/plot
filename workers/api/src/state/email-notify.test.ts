import { describe, expect, it } from "vitest";

import { priorityDeepLinkUrl } from "./email-notify";

describe("priorityDeepLinkUrl", () => {
  it("builds a canonical /p/ priority deep link", () => {
    expect(
      priorityDeepLinkUrl(
        "https://app.plot.day",
        "019d91c2-4d0d-798e-b920-4340faf6b2ff"
      )
    ).toBe("https://app.plot.day/p/Ca5nzyiWJLyDo43mNqPW6");
  });

  it("does not emit the deprecated ?tab=activity query param", () => {
    const url = priorityDeepLinkUrl(
      "https://app.plot.day",
      "019d91c2-4d0d-798e-b920-4340faf6b2ff"
    );
    // The old digest link was `/{id}?tab=activity`, a stale bare-segment form
    // whose query param is ignored by the app router. The canonical form has
    // no query string at all.
    expect(url).not.toContain("tab=activity");
    expect(url).not.toContain("?");
  });
});
