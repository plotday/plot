import { describe, expect, it } from "vitest";

import {
  bandToImportance,
  fallbackBand,
  IMPORTANCE_RUBRIC,
  parseBand,
} from "./band";

describe("bandToImportance", () => {
  it("maps suppress and low below the 50 gate", () => {
    expect(bandToImportance("suppress")).toBeLessThan(50);
    expect(bandToImportance("low")).toBeLessThan(50);
  });
  it("maps normal and elevated at/above the gate, elevated highest", () => {
    expect(bandToImportance("normal")).toBeGreaterThanOrEqual(50);
    expect(bandToImportance("elevated")).toBeGreaterThan(bandToImportance("normal"));
  });
  it("preserves strict ordering suppress < low < normal < elevated", () => {
    const seq = ["suppress", "low", "normal", "elevated"] as const;
    const vals = seq.map(bandToImportance);
    expect(vals).toEqual([...vals].sort((a, b) => a - b));
    expect(new Set(vals).size).toBe(4);
  });
});

describe("parseBand", () => {
  it("accepts the four bands case-insensitively", () => {
    expect(parseBand("Suppress")).toBe("suppress");
    expect(parseBand(" elevated ")).toBe("elevated");
  });
  it("rejects junk, numbers, and empty", () => {
    expect(parseBand("urgent")).toBeNull();
    expect(parseBand(50)).toBeNull();
    expect(parseBand(null)).toBeNull();
    expect(parseBand(undefined)).toBeNull();
  });
});

describe("fallbackBand", () => {
  const base = {
    facetAutomation: null,
    facetReach: null,
    facetFormat: null,
    senderEmailAutomated: false,
    senderKnown: false,
  };
  it("suppresses automated list mail", () => {
    expect(
      fallbackBand({ ...base, facetAutomation: "automated", facetReach: "list" }),
    ).toBe("low");
  });
  it("suppresses promotion-format mail", () => {
    expect(fallbackBand({ ...base, facetFormat: "promotion" })).toBe("low");
  });
  it("suppresses an unknown no-reply sender", () => {
    expect(
      fallbackBand({ ...base, senderEmailAutomated: true, senderKnown: false }),
    ).toBe("low");
  });
  it("does NOT suppress a no-reply sender the recipient already engages with", () => {
    expect(
      fallbackBand({ ...base, senderEmailAutomated: true, senderKnown: true }),
    ).toBe("normal");
  });
  it("defaults ordinary mail to normal (surfaces)", () => {
    expect(fallbackBand({ ...base, facetAutomation: "human", facetReach: "direct" })).toBe(
      "normal",
    );
  });
});

describe("IMPORTANCE_RUBRIC", () => {
  it("names all four bands and omits a numeric 0-100 instruction", () => {
    for (const b of ["suppress", "low", "normal", "elevated"]) {
      expect(IMPORTANCE_RUBRIC).toContain(b);
    }
    expect(IMPORTANCE_RUBRIC).not.toMatch(/0-100|0 to 100/);
  });
});
