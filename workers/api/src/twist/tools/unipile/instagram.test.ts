import { describe, expect, test } from "vitest";
import { normalizeUsername } from "./instagram";

describe("normalizeUsername", () => {
  test("strips leading @ and trims", () => {
    expect(normalizeUsername("  @alice ")).toBe("alice");
  });
  test("returns null for empty", () => {
    expect(normalizeUsername("@")).toBeNull();
  });
});
