import type {
  ChatAttachment,
  ChatMessage,
  ChatMessageReaction,
  ChatProfile,
  ChatThread,
  LinkedInInvitation,
  LinkedInPost,
  LinkedInComment,
  LinkedInPostReaction,
} from "@plotday/unipile";

import type {
  UnipileAttachment,
  UnipileChat,
  UnipileInvitation,
  UnipileMessage,
  UnipileReactionCounter,
  UnipileRelation,
  UnipileUser,
  UnipilePostRaw,
  UnipileCommentRaw,
  UnipilePostReactionRaw,
} from "./types";

export function normalizeProfile(
  user: UnipileUser,
  provider: string,
  isSelf = false
): ChatProfile {
  const handle = user.public_identifier ?? null;
  const name = (user.display_name && user.display_name.trim()) || handle || "Unknown";
  return {
    id: user.id,
    isSelf,
    handle,
    name,
    subtitle: user.description ?? user.specifics?.headline ?? null,
    email: user.specifics?.email ?? user.emails?.[0] ?? null,
    phone: user.specifics?.phone ?? null,
    pictureUrl: user.public_picture_url ?? null,
    profileUrl:
      user.profile_url ??
      (provider === "linkedin" && handle
        ? `https://www.linkedin.com/in/${handle}`
        : null),
  };
}

/**
 * v2 chats embed their participants: group chats under `participants[].user`
 * (with a per-participant `is_self`), 1:1 chats under a single `user` (the
 * other party — self is implicit). No separate attendees fetch is needed.
 */
export function normalizeChat(chat: UnipileChat, provider: string): ChatThread {
  let participants: ChatProfile[];
  if (chat.participants && chat.participants.length > 0) {
    participants = chat.participants.map((p) =>
      normalizeProfile(p.user, provider, p.is_self === true)
    );
  } else if (chat.user) {
    participants = [normalizeProfile(chat.user, provider, false)];
  } else {
    participants = [];
  }
  return {
    id: chat.id,
    title: chat.name,
    isGroup: chat.is_group === true,
    participants,
    lastMessagePreview: null,
    lastActivityAt: new Date(chat.last_message_timestamp),
    unreadCount: chat.unread_count,
    archived: chat.is_archived === true,
    folder: chat.folders?.[0] ?? null,
    url:
      provider === "linkedin"
        ? `https://www.linkedin.com/messaging/thread/${chat.id}/`
        : null,
  };
}

export function normalizeMessage(msg: UnipileMessage, provider: string): ChatMessage {
  return {
    id: msg.id,
    chatId: msg.chat_id,
    senderId: msg.sender_id,
    // v2 embeds the sender profile on each message. WhatsApp group chats carry
    // no participant roster, so this is the only place the sender's real name
    // and avatar are available for author resolution downstream.
    sender: msg.sender ? normalizeProfile(msg.sender, provider, msg.is_sender === true) : null,
    sentByMe: msg.is_sender === true,
    eventType: msg.is_event === true ? msg.event_type ?? "unknown" : null,
    sentAt: new Date(msg.timestamp),
    text: msg.text ?? "",
    attachments: (msg.attachments ?? []).map(normalizeAttachment),
    // The live API sometimes returns a counter entry with no `value` (the type
    // optimistically declares `value: string`); drop those so a valueless
    // reaction never propagates downstream as the emoji `"undefined"`.
    reactions: (msg.reactions_counter ?? [])
      .filter((r) => Boolean(r.value))
      .map(normalizeReaction),
  };
}

function normalizeReaction(r: UnipileReactionCounter): ChatMessageReaction {
  return {
    value: r.value,
    // v2 reactions_counter is an aggregate; it does not carry per-reactor ids.
    senderId: "",
    sentByMe: r.reacted === true,
  };
}

function normalizeAttachment(a: UnipileAttachment): ChatAttachment {
  let kind: ChatAttachment["kind"] = "other";
  if (a.type === "img") kind = "image";
  else if (a.type === "video") kind = "video";
  else if (a.type === "audio") kind = "audio";
  else if (a.type === "file") kind = "file";
  return {
    id: a.id,
    kind,
    name: a.name ?? null,
    url: a.url ?? "",
    contentType: a.mimetype ?? null,
    byteSize: a.file_size ?? null,
  };
}

/**
 * Normalize a v2 LinkedIn received invitation. The inviter is embedded under
 * `user`; v2 has no `shared_secret` (accept/ignore is keyed on the request id).
 */
export function normalizeInvitation(inv: UnipileInvitation): LinkedInInvitation {
  return {
    id: inv.id,
    inviter: normalizeProfile(inv.user, "linkedin", false),
    message: inv.message ?? null,
    sentAt: inv.created_at ? new Date(inv.created_at) : new Date(0),
  };
}

/**
 * Normalize a v2 LinkedIn relation (1st-degree connection) into ChatProfile.
 * The profile is embedded under `user`.
 */
export function normalizeRelation(rel: UnipileRelation): ChatProfile {
  return normalizeProfile(rel.user, "linkedin", false);
}

export function normalizePost(raw: UnipilePostRaw, provider: string): LinkedInPost {
  const id = raw.social_id ?? raw.id ?? "";
  const when = raw.date ?? raw.parsed_datetime;
  const author = raw.author
    ? normalizeProfile(raw.author, provider, true)
    : { id: "", isSelf: true, handle: null, name: "You", subtitle: null, email: null, phone: null, pictureUrl: null, profileUrl: null };
  return {
    id,
    text: raw.text ?? "",
    createdAt: when ? new Date(when) : new Date(0),
    author,
    url: raw.share_url ?? raw.author?.public_profile_url ?? null,
  };
}

export function normalizeComment(raw: UnipileCommentRaw, provider: string): LinkedInComment {
  const when = raw.date ?? raw.parsed_datetime;
  const author = raw.author
    ? normalizeProfile(raw.author, provider, false)
    : { id: "", isSelf: false, handle: null, name: "Unknown", subtitle: null, email: null, phone: null, pictureUrl: null, profileUrl: null };
  return {
    id: raw.id,
    text: raw.text ?? "",
    createdAt: when ? new Date(when) : new Date(0),
    author,
    parentCommentId: raw.parent_comment_id ?? raw.parent ?? null,
  };
}

export function normalizePostReaction(raw: UnipilePostReactionRaw, provider: string): LinkedInPostReaction {
  const a = raw.author;
  const profile = a ? normalizeProfile(a, provider, false) : null;
  return {
    reactorId: profile?.id ?? "",
    reactorName: profile?.name ?? null,
    reactorPictureUrl: profile?.pictureUrl ?? null,
    reactionType: raw.reaction_type ?? raw.value ?? "like",
  };
}
