import { describe, expect, it } from "vitest";
import { slackNameToUnicode, unicodeToSlackName } from "./slack-emoji";

describe("slackNameToUnicode", () => {
  it("maps core shortcodes", () => {
    expect(slackNameToUnicode("+1")).toBe("👍");
    expect(slackNameToUnicode("tada")).toBe("🎉");
    expect(slackNameToUnicode("fire")).toBe("🔥");
  });

  it("maps a long-tail shortcode absent from the old 60-entry table", () => {
    // 🦄 was not in the curated table; it must resolve now.
    expect(slackNameToUnicode("unicorn_face")).toBe("🦄");
  });

  it("maps skin-tone variants", () => {
    expect(slackNameToUnicode("thumbsup::skin-tone-2")).toBe("👍🏻");
    expect(slackNameToUnicode("wave::skin-tone-6")).toBe("👋🏿");
  });

  it("returns null for unknown / custom shortcodes", () => {
    expect(slackNameToUnicode("party_parrot")).toBeNull();
    expect(slackNameToUnicode("not_a_real_emoji_xyz")).toBeNull();
  });
});

describe("unicodeToSlackName", () => {
  it("maps base graphemes back to a valid Slack name (round-trips)", () => {
    const name = unicodeToSlackName("👍");
    expect(name).not.toBeNull();
    expect(slackNameToUnicode(name as string)).toBe("👍");
  });

  it("maps skin-toned graphemes to ::skin-tone-N and round-trips", () => {
    const name = unicodeToSlackName("👍🏽");
    expect(name).toMatch(/::skin-tone-4$/);
    expect(slackNameToUnicode(name as string)).toBe("👍🏽");
  });

  it("degrades a compound multi-tone grapheme to the base name (no tone)", () => {
    // Synthetic base + two distinct modifiers exercises the fallback.
    const name = unicodeToSlackName("👍🏻🏿");
    expect(name).not.toBeNull();
    expect(name).not.toContain("::skin-tone-");
    expect(slackNameToUnicode(name as string)).toBe("👍");
  });

  it("returns null for a grapheme Slack has no name for", () => {
    expect(unicodeToSlackName("🫩")).toBeNull(); // U+1FAE9, absent from emoji-data v15.1.2
  });
});
