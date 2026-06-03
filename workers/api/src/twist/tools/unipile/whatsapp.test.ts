import { describe, expect, test } from "vitest";
import { phoneToJid } from "./whatsapp";

describe("phoneToJid", () => {
  test("strips non-digits and appends domain", () => {
    expect(phoneToJid("+1 (555) 123-4567")).toBe("15551234567@s.whatsapp.net");
  });
  test("passes through an existing JID", () => {
    expect(phoneToJid("15551234567@s.whatsapp.net")).toBe("15551234567@s.whatsapp.net");
  });
  test("returns null for empty/garbage", () => {
    expect(phoneToJid("abc")).toBeNull();
  });
});
