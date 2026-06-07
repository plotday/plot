import { describe, expect, it } from "vitest";

import { isNameUpgrade } from "./contacts";

describe("isNameUpgrade (longest-wins on the connector import path)", () => {
  it("fills when there is no existing name", () => {
    expect(isNameUpgrade(null, "Beth")).toBe(true);
    expect(isNameUpgrade(undefined, "Beth")).toBe(true);
    expect(isNameUpgrade("", "B")).toBe(true);
  });

  it("upgrades to a strictly longer name", () => {
    expect(isNameUpgrade("Beth", "Beth Round")).toBe(true);
  });

  it("ignores a shorter name", () => {
    expect(isNameUpgrade("Beth Round", "Beth")).toBe(false);
  });

  it("ignores an equal-length name", () => {
    expect(isNameUpgrade("Beth", "Beta")).toBe(false);
  });

  it("ignores an empty or missing incoming name", () => {
    expect(isNameUpgrade("Beth", undefined)).toBe(false);
    expect(isNameUpgrade("Beth", null)).toBe(false);
    expect(isNameUpgrade("Beth", "")).toBe(false);
  });
});
