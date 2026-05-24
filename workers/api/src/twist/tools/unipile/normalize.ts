import type {
  LinkedInAttachment,
  LinkedInChat,
  LinkedInInvitation,
  LinkedInMessage,
  LinkedInProfile,
} from "@plotday/unipile";

import type {
  UnipileAttachment,
  UnipileAttendee,
  UnipileChat,
  UnipileInvitation,
  UnipileMessage,
  UnipileRelation,
} from "./types";

export function normalizeProfile(att: UnipileAttendee): LinkedInProfile {
  const publicIdentifier = att.specifics?.public_identifier ?? null;
  const fullName =
    (att.name && att.name.trim()) ||
    publicIdentifier ||
    "Unknown";
  return {
    id: att.provider_id,
    isSelf: att.is_self === 1,
    publicIdentifier,
    fullName,
    headline: att.specifics?.headline ?? null,
    email: att.specifics?.email ?? null,
    pictureUrl: att.picture_url ?? null,
    url:
      att.profile_url ??
      (publicIdentifier
        ? `https://www.linkedin.com/in/${publicIdentifier}`
        : null),
  };
}

export function normalizeChat(
  chat: UnipileChat,
  attendees: UnipileAttendee[]
): LinkedInChat {
  // Keep self in the participants list so message-sender lookups by id
  // (`msg.senderId === participant.id`) succeed for the connected user's
  // own messages. Callers building thread.contacts filter on `isSelf`.
  const profiles = attendees.map(normalizeProfile);
  return {
    id: chat.id,
    title: chat.name,
    isGroup: chat.type === 1,
    participants: profiles,
    lastMessagePreview: null,
    lastActivityAt: new Date(chat.timestamp),
    unreadCount: chat.unread_count,
    archived: chat.archived === 1,
    url: `https://www.linkedin.com/messaging/thread/${chat.provider_id}/`,
  };
}

export function normalizeMessage(msg: UnipileMessage): LinkedInMessage {
  return {
    id: msg.id,
    chatId: msg.chat_id,
    senderId: msg.sender_id,
    sentByMe: msg.is_sender === 1,
    sentAt: new Date(msg.timestamp),
    text: msg.text ?? "",
    attachments: (msg.attachments ?? []).map(normalizeAttachment),
  };
}

function normalizeAttachment(a: UnipileAttachment): LinkedInAttachment {
  let kind: LinkedInAttachment["kind"] = "other";
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
  const publicIdentifier = inviter.inviter_public_identifier ?? null;
  const trimmedName = inviter.inviter_name?.trim();
  const fullName = trimmedName || publicIdentifier || "Unknown";
  return {
    id: inv.id,
    sharedSecret: inv.specifics.shared_secret,
    inviter: {
      id: inviter.inviter_id,
      isSelf: false,
      publicIdentifier,
      fullName,
      headline: inviter.inviter_description ?? null,
      email: null,
      pictureUrl: inviter.inviter_profile_picture_url ?? null,
      url: publicIdentifier
        ? `https://www.linkedin.com/in/${publicIdentifier}`
        : null,
    },
    message: inv.invitation_text,
    sentAt: new Date(inv.parsed_datetime),
  };
}

/**
 * Normalize a Unipile `UserRelation` (from GET /users/relations) into Plot's
 * `LinkedInProfile` shape. Relations are 1st-degree connections; they never
 * represent the connected account itself, so `isSelf` is always false.
 * Email is never present in this endpoint's payload — separate profile
 * fetches would be needed, but those count toward LinkedIn's ~100/day
 * profile-retrieval ceiling and are intentionally avoided.
 */
export function normalizeRelation(rel: UnipileRelation): LinkedInProfile {
  const first = rel.first_name?.trim() ?? "";
  const last = rel.last_name?.trim() ?? "";
  const joined = [first, last].filter(Boolean).join(" ");
  const fullName = joined || rel.public_identifier || "Unknown";
  const headlineTrimmed = rel.headline?.trim() ?? "";
  return {
    id: rel.member_id,
    isSelf: false,
    publicIdentifier: rel.public_identifier || null,
    fullName,
    headline: headlineTrimmed || null,
    email: null,
    pictureUrl: rel.profile_picture_url ?? null,
    url:
      rel.public_profile_url ||
      (rel.public_identifier
        ? `https://www.linkedin.com/in/${rel.public_identifier}`
        : null),
  };
}
