import { describe, expect, it } from "vitest";

import { isFyiFormat } from "../src/ts-hybrid-stages";

describe("isFyiFormat", () => {
  it("routes low-signal formats to FYI", () => {
    for (const format of ["promotion", "reading", "receipt", "notification"]) {
      expect(isFyiFormat({ format })).toBe(true);
    }
  });

  it("keeps human collaboration out of FYI", () => {
    expect(isFyiFormat({ format: "message" })).toBe(false);
    expect(isFyiFormat({ format: "chat" })).toBe(false);
  });

  it("keeps actionable formats out of FYI", () => {
    expect(isFyiFormat({ format: "invoice" })).toBe(false);
    expect(isFyiFormat({ format: "otp" })).toBe(false);
    expect(isFyiFormat({ format: "confirm" })).toBe(false);
  });

  it("fails open on null/absent format", () => {
    expect(isFyiFormat(null)).toBe(false);
    expect(isFyiFormat({})).toBe(false);
    expect(isFyiFormat({ automation: "automated" })).toBe(false);
  });
});
