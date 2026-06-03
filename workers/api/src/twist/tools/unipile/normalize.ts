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
  UnipileAttendee,
  UnipileChat,
  UnipileInvitation,
  UnipileMessage,
  UnipileMessageReaction,
  UnipileRelation,
} from "./types";

export function normalizeProfile(att: UnipileAttendee, provider: string): ChatProfile {
  const handle = att.specifics?.public_identifier ?? null;
  const name =
    (att.name && att.name.trim()) ||
    handle ||
    "Unknown";
  const publicIdentifier = handle;
  return {
    id: att.provider_id,
    isSelf: att.is_self === 1,
    handle,
    name,
    subtitle: att.specifics?.headline ?? null,
    email: att.specifics?.email ?? null,
    phone: att.specifics?.phone ?? null,
    pictureUrl: att.picture_url ?? null,
    profileUrl:
      att.profile_url ??
      (provider === "linkedin" && publicIdentifier
        ? `https://www.linkedin.com/in/${publicIdentifier}`
        : null),
  };
}

export function normalizeChat(
  chat: UnipileChat,
  attendees: UnipileAttendee[],
  provider: string
): ChatThread {
  // Keep self in the participants list so message-sender lookups by id
  // (`msg.senderId === participant.id`) succeed for the connected user's
  // own messages. Callers building thread.contacts filter on `isSelf`.
  const participants = attendees.map((a) => normalizeProfile(a, provider));
  return {
    id: chat.id,
    title: chat.name,
    isGroup: chat.type === 1,
    participants,
    lastMessagePreview: null,
    lastActivityAt: new Date(chat.timestamp),
    unreadCount: chat.unread_count,
    archived: chat.archived === 1,
    folder: chat.folder ?? null,
    url: provider === "linkedin" ? `https://www.linkedin.com/messaging/thread/${chat.provider_id}/` : null,
  };
}

export function normalizeMessage(msg: UnipileMessage): ChatMessage {
  return {
    id: msg.id,
    chatId: msg.chat_id,
    senderId: msg.sender_id,
    sentByMe: msg.is_sender === 1,
    eventType: msg.is_event === 1 ? msg.event_type ?? "unknown" : null,
    sentAt: new Date(msg.timestamp),
    text: msg.text ?? "",
    attachments: (msg.attachments ?? []).map(normalizeAttachment),
    reactions: (msg.reactions ?? []).map(normalizeReaction),
  };
}

function normalizeReaction(r: UnipileMessageReaction): ChatMessageReaction {
  return {
    value: r.value,
    senderId: r.sender_id,
    sentByMe: r.is_sender === true,
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

export function normalizeInvitation(
  inv: UnipileInvitation
): LinkedInInvitation {
  const inviter = inv.inviter;
  const handle = inviter.inviter_public_identifier ?? null;
  const trimmedName = inviter.inviter_name?.trim();
  const name = trimmedName || handle || "Unknown";
  return {
    id: inv.id,
    sharedSecret: inv.specifics.shared_secret,
    inviter: {
      id: inviter.inviter_id,
      isSelf: false,
      handle,
      name,
      subtitle: inviter.inviter_description ?? null,
      email: null,
      phone: null,
      pictureUrl: inviter.inviter_profile_picture_url ?? null,
      profileUrl: handle
        ? `https://www.linkedin.com/in/${handle}`
        : null,
    },
    message: inv.invitation_text,
    sentAt: new Date(inv.parsed_datetime),
  };
}

/**
 * Normalize a Unipile `UserRelation` (from GET /users/relations) into Plot's
 * `ChatProfile` shape. Relations are 1st-degree connections; they never
 * represent the connected account itself, so `isSelf` is always false.
 * Email is never present in this endpoint's payload — separate profile
 * fetches would be needed, but those count toward LinkedIn's ~100/day
 * profile-retrieval ceiling and are intentionally avoided.
 */
export function normalizeRelation(rel: UnipileRelation): ChatProfile {
  const first = rel.first_name?.trim() ?? "";
  const last = rel.last_name?.trim() ?? "";
  const joined = [first, last].filter(Boolean).join(" ");
  const handle = rel.public_identifier || null;
  const name = joined || handle || "Unknown";
  const subtitleTrimmed = rel.headline?.trim() ?? "";
  return {
    id: rel.member_id,
    isSelf: false,
    handle,
    name,
    subtitle: subtitleTrimmed || null,
    email: null,
    phone: null,
    pictureUrl: rel.profile_picture_url ?? null,
    profileUrl:
      rel.public_profile_url ||
      (rel.public_identifier
        ? `https://www.linkedin.com/in/${rel.public_identifier}`
        : null),
  };
}
