/**
 * GitHub's reaction "content" values (the fixed enum accepted by
 * `POST /reactions` endpoints) mapped to their Unicode emoji, and back.
 * GitHub's reaction set is fixed — no custom emoji, no open Unicode — so
 * this is the connector's `reactionCapabilities` allow-list too.
 */
export const GITHUB_REACTION_TO_EMOJI: Record<string, string> = {
  "+1": "👍",
  "-1": "👎",
  laugh: "😄",
  hooray: "🎉",
  confused: "😕",
  heart: "❤️",
  rocket: "🚀",
  eyes: "👀",
};

export const EMOJI_TO_GITHUB_REACTION: Record<string, string> = Object.fromEntries(
  Object.entries(GITHUB_REACTION_TO_EMOJI).map(([content, emoji]) => [emoji, content])
);

export const ALLOWED_REACTION_EMOJI: readonly string[] = Object.freeze(
  Object.values(GITHUB_REACTION_TO_EMOJI)
);
