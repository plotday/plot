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
} from "./types";

export function normalizeProfile(att: UnipileAttendee): LinkedInProfile {
  const publicIdentifier = att.specifics?.public_identifier ?? null;
  const fullName =
    (att.name && att.name.trim()) ||
    publicIdentifier ||
    "Unknown";
  return {
    id: att.provider_id,
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
  const profiles = attendees
    .filter((a) => a.is_self === 0)
    .map(normalizeProfile);
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
  return {
    id: inv.id,
    sharedSecret: inv.shared_secret,
    inviter: normalizeProfile(inv.inviter),
    message: inv.message,
    sentAt: new Date(inv.created_at),
  };
}
