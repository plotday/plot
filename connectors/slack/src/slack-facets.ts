import type { ThreadFacets } from "@plotday/twister/facets";
import type { SlackMessage } from "./slack-api";

// Reach is inferred from the channelId prefix (the channel object isn't in
// scope at save time):
//   C = public or modern private channel        → list (broadcast context)
//   G = group/MPIM OR legacy (pre-2020) private  → treated as direct (best-effort;
//       an old private channel is misread as direct, acceptable under fail-open)
//   D = IM (DM)                                  → direct
function reachForChannel(channelId: string): "direct" | "list" {
  return channelId.startsWith("C") ? "list" : "direct";
}

// A long Slack post reads as a "message" rather than a quick "chat".
const CHAT_MAX_LENGTH = 1000;

/**
 * Compute facets for a Slack thread's parent message. Channel kind is inferred
 * from the channelId prefix (the full channel object is not in scope at save
 * time); this is best-effort per the facet design's fail-open principle.
 */
export function slackFacets(parent: SlackMessage, channelId: string): ThreadFacets {
  const isBot = isBotShaped(parent);
  const text = parent.text ?? "";
  return {
    format: text.length > CHAT_MAX_LENGTH ? "message" : "chat",
    automation: isBot ? "automated" : "human",
    reach: reachForChannel(channelId),
  };
}

function isBotShaped(message: SlackMessage): boolean {
  return Boolean(message.bot_id) || message.subtype === "bot_message" || !message.user;
}

/**
 * Facets for the single permanent link of a direct or group conversation.
 *
 * `reach` is `direct` by construction (a DM addresses the user), and the
 * conversation reads as `chat` regardless of any one message's length. For
 * `automation` the batch is judged as a whole, and only an all-bot batch is
 * `automated`: a muteable `automated` verdict that hides a real person is the
 * one failure classification must never produce, so a single human-shaped
 * message makes the conversation `human`.
 */
export function slackDmFacets(messages: SlackMessage[]): ThreadFacets {
  const isBot = messages.length > 0 && messages.every(isBotShaped);
  return {
    format: "chat",
    automation: isBot ? "automated" : "human",
    reach: "direct",
  };
}
