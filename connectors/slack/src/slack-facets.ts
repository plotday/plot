import type { ThreadFacets } from "@plotday/twister/facets";
import type { SlackMessage } from "./slack-api";

// Channel-id prefixes: C = public/private channel, G = group/MPIM, D = IM (DM).
// Channels are broadcast contexts (reach=list); DMs/group-DMs are direct.
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
  const isBot = Boolean(parent.bot_id) || parent.subtype === "bot_message" || !parent.user;
  const text = parent.text ?? "";
  return {
    format: text.length > CHAT_MAX_LENGTH ? "message" : "chat",
    automation: isBot ? "automated" : "human",
    reach: reachForChannel(channelId),
  };
}
