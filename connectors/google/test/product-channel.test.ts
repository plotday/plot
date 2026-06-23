import { describe, it, expect } from "vitest";
import { namespace, parse, productKeyOf } from "../src/product-channel";

describe("namespace", () => {
  it("joins product and rawId with ':'", () => {
    expect(namespace("calendar", "primary")).toBe("calendar:primary");
    expect(namespace("mail", "INBOX")).toBe("mail:INBOX");
  });

  it("handles rawId that itself contains ':'", () => {
    expect(namespace("mail", "Label_42:x")).toBe("mail:Label_42:x");
  });
});

describe("parse", () => {
  it("splits on the FIRST ':' only", () => {
    expect(parse("calendar:primary")).toEqual({ product: "calendar", rawId: "primary" });
    expect(parse("mail:Label_42:x")).toEqual({ product: "mail", rawId: "Label_42:x" });
    expect(parse("tasks:tasks:subtask:123")).toEqual({
      product: "tasks",
      rawId: "tasks:subtask:123",
    });
  });

  it("returns empty product when no ':' is present", () => {
    expect(parse("noprefix")).toEqual({ product: "", rawId: "noprefix" });
  });
});

describe("productKeyOf", () => {
  it("returns the substring before the first ':'", () => {
    expect(productKeyOf("calendar:primary")).toBe("calendar");
    expect(productKeyOf("mail:Label_42:x")).toBe("mail");
    expect(productKeyOf("tasks:t:sub")).toBe("tasks");
  });

  it("returns null when no ':' is present", () => {
    expect(productKeyOf("noprefix")).toBeNull();
  });
});

describe("round-trip", () => {
  it("parse(namespace(p, id)) === {product: p, rawId: id}", () => {
    const cases: [string, string][] = [
      ["calendar", "primary"],
      ["mail", "Label_42:x"],
      ["tasks", "MDEwMTAxMDEwMTA="],
      ["contacts", "contacts"],
    ];
    for (const [product, rawId] of cases) {
      expect(parse(namespace(product, rawId))).toEqual({ product, rawId });
    }
  });
});
