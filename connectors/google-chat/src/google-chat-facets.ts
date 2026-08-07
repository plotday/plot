import type { ThreadFacets } from "@plotday/twister/facets";

import type { Message } from "./google-chat-api";

// A long Google Chat post reads as a "message" rather than a quick "chat".
const CHAT_MAX_LENGTH = 1000;

// Google Chat senders carry an explicit type; only an explicit BOT counts as
// bot-shaped. A missing sender or type falls open to human — a muteable
// `automated` verdict that hides a real person is the one failure
// classification must never produce.
function isBotMessage(message: Message): boolean {
  return message.sender?.type === "BOT";
}

/**
 * Facets for a thread in a named space. Named spaces are broadcast context,
 * so `reach` is `list`; format and automation are judged from the thread's
 * parent message, best-effort per the facet design's fail-open principle.
 */
export function googleChatThreadFacets(parent: Message): ThreadFacets {
  const text = parent.text ?? "";
  return {
    format: text.length > CHAT_MAX_LENGTH ? "message" : "chat",
    automation: isBotMessage(parent) ? "automated" : "human",
    reach: "list",
  };
}

/**
 * Facets for a thread in a DM or group chat.
 *
 * `reach` is `direct` by construction (a DM addresses the user), and the
 * conversation reads as `chat` regardless of any one message's length. For
 * `automation` the batch is judged as a whole, and only an all-bot batch is
 * `automated`: a single human-shaped message makes the conversation `human`.
 */
export function googleChatDmFacets(messages: Message[]): ThreadFacets {
  const isBot = messages.length > 0 && messages.every(isBotMessage);
  return {
    format: "chat",
    automation: isBot ? "automated" : "human",
    reach: "direct",
  };
}
