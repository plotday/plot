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
    const reordered = JSON.parse(JSON.stringify(DEFAULTS)) as typeof DEFAULTS;
    expect(paramsHash(reordered)).toBe(paramsHash(DEFAULTS));
  });
});
