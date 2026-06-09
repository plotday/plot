import { describe, expect, it } from "vitest";
import { FACET_REGISTRY, FacetFiltersSchema, registryPromptBlock } from "./facet-registry";

describe("facet-registry", () => {
  it("lists every format/automation/reach value with a description", () => {
    expect(Object.keys(FACET_REGISTRY.format.values)).toContain("reading");
    expect(Object.keys(FACET_REGISTRY.format.values)).toContain("notification");
    for (const dim of ["format", "automation", "reach"] as const) {
      for (const desc of Object.values<string>(FACET_REGISTRY[dim].values)) {
        expect(desc.length).toBeGreaterThan(0);
      }
    }
  });

  it("prompt block mentions every value", () => {
    const block = registryPromptBlock();
    for (const dim of ["format", "automation", "reach"] as const) {
      for (const value of Object.keys(FACET_REGISTRY[dim].values)) {
        expect(block).toContain(value);
      }
    }
  });

  it("schema accepts a valid filter object", () => {
    const parsed = FacetFiltersSchema.parse({
      format: { include: ["reading"], exclude: ["notification"] },
      trustedSendersOnly: true,
    });
    expect(parsed.format?.exclude).toEqual(["notification"]);
  });

  it("schema rejects an unknown format value", () => {
    expect(() => FacetFiltersSchema.parse({ format: { include: ["bogus"] } })).toThrow();
  });
});
