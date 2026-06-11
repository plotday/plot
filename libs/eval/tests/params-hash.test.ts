import { describe, expect, it } from "vitest";

import { DEFAULTS, DEFAULTS_LLM, paramsHash } from "@plotday/classifier";

describe("paramsHash", () => {
  it("is a stable 8-hex-char digest", () => {
    expect(paramsHash(DEFAULTS_LLM)).toMatch(/^[0-9a-f]{8}$/);
    expect(paramsHash(DEFAULTS_LLM)).toBe(paramsHash(DEFAULTS_LLM));
  });

  it("changes when any parameter changes", () => {
    expect(paramsHash({ ...DEFAULTS, scoreThreshold: 0.09 })).not.toBe(paramsHash(DEFAULTS));
    expect(paramsHash(DEFAULTS_LLM)).not.toBe(paramsHash(DEFAULTS));
  });

  it("is key-order independent", () => {
    // Rebuild with different insertion order at top level and nested level.
    // Pre-spread duplicates force JS insertion-order semantics (first insertion wins);
    // TS correctly warns that the later spread overwrites them — that's the point.
    const reordered = {
      // @ts-ignore TS2783 – intentional duplicate to force a different insertion order
      scoreThreshold: DEFAULTS.scoreThreshold,
      ...DEFAULTS,
      weights: {
        // @ts-ignore TS2783 – intentional duplicate to force a different insertion order
        title: DEFAULTS.weights.title,
        ...DEFAULTS.weights,
      },
    };
    expect(Object.keys(reordered)[0]).not.toBe(Object.keys(DEFAULTS)[0]); // sanity: order really differs
    expect(paramsHash(reordered)).toBe(paramsHash(DEFAULTS));
  });
});
