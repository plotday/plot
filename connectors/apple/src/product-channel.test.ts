import { describe, expect, it } from "vitest";

import { namespace, parse, productKeyOf } from "./product-channel";

describe("product-channel", () => {
  it("round-trips a namespaced id, splitting on the first colon only", () => {
    const raw = "/1234/calendars/home:set/"; // rawId itself contains a colon
    const ns = namespace("calendar", raw);
    expect(ns).toBe("calendar:/1234/calendars/home:set/");
    expect(parse(ns)).toEqual({ product: "calendar", rawId: raw });
  });

  it("parses an un-prefixed id as empty product", () => {
    expect(parse("INBOX")).toEqual({ product: "", rawId: "INBOX" });
  });

  it("productKeyOf returns the prefix or null", () => {
    expect(productKeyOf("mail:INBOX")).toBe("mail");
    expect(productKeyOf("INBOX")).toBeNull();
  });
});
