import { describe, expect, it } from "vitest";

import { seeWithinToMs } from "./push-notify";

describe("seeWithinToMs", () => {
  it('converts minutes correctly', () => {
    expect(seeWithinToMs('{"value":30,"unit":"minutes"}')).toBe(1_800_000);
  });

  it('converts hours correctly', () => {
    expect(seeWithinToMs('{"value":2,"unit":"hours"}')).toBe(7_200_000);
  });

  it('converts days correctly', () => {
    expect(seeWithinToMs('{"value":1,"unit":"days"}')).toBe(86_400_000);
  });

  it('returns null for null input', () => {
    expect(seeWithinToMs(null)).toBeNull();
  });

  it('returns null for malformed JSON', () => {
    expect(seeWithinToMs('not-json')).toBeNull();
  });

  it('returns null for unknown unit', () => {
    expect(seeWithinToMs('{"value":5,"unit":"weeks"}')).toBeNull();
  });

  it('returns null when value is missing', () => {
    expect(seeWithinToMs('{"unit":"hours"}')).toBeNull();
  });

  it('returns null when unit is missing', () => {
    expect(seeWithinToMs('{"value":1}')).toBeNull();
  });
});
