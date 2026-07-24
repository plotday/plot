import { describe, expect, it } from "vitest";
import { baseEmail, canonicalizeEmail } from "./canonical-email";
import corpus from "./canonical-email-cases.json";

describe("canonical-email shared corpus", () => {
  for (const c of corpus.cases) {
    it(`canonicalizeEmail(${JSON.stringify(c.input)}) — ${c.note}`, () => {
      expect(canonicalizeEmail(c.input)).toBe(c.canonical);
    });
    it(`baseEmail(${JSON.stringify(c.input)}) — ${c.note}`, () => {
      expect(baseEmail(c.input)).toBe(c.base);
    });
  }
});

describe("canonical-email properties", () => {
  it("is idempotent", () => {
    for (const c of corpus.cases) {
      expect(canonicalizeEmail(canonicalizeEmail(c.input))).toBe(c.canonical);
      expect(baseEmail(baseEmail(c.input))).toBe(c.base);
    }
  });

  it("never widens identity for a non-gmail domain", () => {
    // Two distinct acme addresses must never collapse to the same key.
    expect(canonicalizeEmail("a.b@acme.com")).not.toBe(canonicalizeEmail("ab@acme.com"));
    expect(baseEmail("f+ap@acme.com")).not.toBe(baseEmail("f@acme.com"));
  });
});
