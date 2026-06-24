import type {
  ChatAttachment,
  ChatMessage,
  ChatMessageReaction,
  ChatProfile,
  ChatThread,
  LinkedInInvitation,
} from "@plotday/unipile";

import type {
  UnipileAttachment,
  UnipileChat,
  UnipileInvitation,
  UnipileMessage,
  UnipileReactionCounter,
  UnipileRelation,
  UnipileUser,
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
    subtitle: user.specifics?.headline ?? null,
    email: user.specifics?.email ?? null,
    phone: user.specifics?.phone ?? null,
    pictureUrl: user.public_picture_url ?? null,
    profileUrl:
      provider === "linkedin" && handle
        ? `https://www.linkedin.com/in/${handle}`
        : null,
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

export function normalizeMessage(msg: UnipileMessage): ChatMessage {
  return {
    id: msg.id,
    chatId: msg.chat_id,
    senderId: msg.sender_id,
    sentByMe: msg.is_sender === true,
    eventType: msg.is_event === true ? msg.event_type ?? "unknown" : null,
    sentAt: new Date(msg.timestamp),
    text: msg.text ?? "",
    attachments: (msg.attachments ?? []).map(normalizeAttachment),
    reactions: (msg.reactions_counter ?? []).map(normalizeReaction),
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
 * Normalize a v2 LinkedIn invitation. The inviter is a v2 `UnipileUser`.
 * LIVE-CONFIRM against a real LinkedIn account (mock has no invitations).
 */
export function normalizeInvitation(inv: UnipileInvitation): LinkedInInvitation {
  const inviter = inv.inviter;
  const handle = inviter?.public_identifier ?? null;
  const name = (inviter?.display_name && inviter.display_name.trim()) || handle || "Unknown";
  return {
    id: inv.id,
    sharedSecret: inv.specifics?.shared_secret ?? "",
    inviter: {
      id: inviter?.id ?? inv.id,
      isSelf: false,
      handle,
      name,
      subtitle: inviter?.specifics?.headline ?? null,
      email: null,
      phone: null,
      pictureUrl: inviter?.public_picture_url ?? null,
      profileUrl: handle ? `https://www.linkedin.com/in/${handle}` : null,
    },
    message: inv.invitation_text ?? null,
    sentAt: inv.parsed_datetime ? new Date(inv.parsed_datetime) : new Date(0),
  };
}

/**
 * Normalize a v2 LinkedIn relation (1st-degree connection) into ChatProfile.
 * LIVE-CONFIRM the exact v2 relation shape against a real LinkedIn account.
 */
export function normalizeRelation(rel: UnipileRelation): ChatProfile {
  const first = rel.first_name?.trim() ?? "";
  const last = rel.last_name?.trim() ?? "";
  const joined = (rel.display_name?.trim() || [first, last].filter(Boolean).join(" ")).trim();
  const handle = rel.public_identifier || null;
  const name = joined || handle || "Unknown";
  const subtitle = rel.headline?.trim() || null;
  const pic = rel.public_picture_url ?? rel.profile_picture_url ?? null;
  return {
    id: rel.member_id ?? rel.id ?? "",
    isSelf: false,
    handle,
    name,
    subtitle,
    email: null,
    phone: null,
    pictureUrl: pic,
    profileUrl:
      rel.public_profile_url ||
      (handle ? `https://www.linkedin.com/in/${handle}` : null),
  };
}
