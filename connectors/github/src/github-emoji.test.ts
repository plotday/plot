import { describe, expect, it } from "vitest";
import {
  ALLOWED_REACTION_EMOJI,
  EMOJI_TO_GITHUB_REACTION,
  GITHUB_REACTION_TO_EMOJI,
} from "./github-emoji";

describe("GITHUB_REACTION_TO_EMOJI", () => {
  it("maps every GitHub reaction content type to its emoji", () => {
    expect(GITHUB_REACTION_TO_EMOJI["+1"]).toBe("👍");
    expect(GITHUB_REACTION_TO_EMOJI["-1"]).toBe("👎");
    expect(GITHUB_REACTION_TO_EMOJI.laugh).toBe("😄");
    expect(GITHUB_REACTION_TO_EMOJI.hooray).toBe("🎉");
    expect(GITHUB_REACTION_TO_EMOJI.confused).toBe("😕");
    expect(GITHUB_REACTION_TO_EMOJI.heart).toBe("❤️");
    expect(GITHUB_REACTION_TO_EMOJI.rocket).toBe("🚀");
    expect(GITHUB_REACTION_TO_EMOJI.eyes).toBe("👀");
  });
});

describe("EMOJI_TO_GITHUB_REACTION", () => {
  it("round-trips every entry in GITHUB_REACTION_TO_EMOJI", () => {
    for (const [content, emoji] of Object.entries(GITHUB_REACTION_TO_EMOJI)) {
      expect(EMOJI_TO_GITHUB_REACTION[emoji]).toBe(content);
    }
  });

  it("returns undefined for an emoji GitHub doesn't support", () => {
    expect(EMOJI_TO_GITHUB_REACTION["🦄"]).toBeUndefined();
  });
});

describe("ALLOWED_REACTION_EMOJI", () => {
  it("lists exactly the 8 GitHub reaction emoji", () => {
    expect(ALLOWED_REACTION_EMOJI).toHaveLength(8);
    expect(new Set(ALLOWED_REACTION_EMOJI)).toEqual(
      new Set(Object.values(GITHUB_REACTION_TO_EMOJI))
    );
  });
});
