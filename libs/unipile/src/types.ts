/**
 * Shared types used across all provider tools in this package.
 *
 * These shapes are intentionally Plot-flavoured, not Unipile-flavoured.
 * If we swap providers later, the impls in workers/api change but these
 * types do not.
 */

export type LinkedInProfile = {
  /** Provider-side member id (Unipile's `provider_id` / LinkedIn member URN). */
  id: string;
  /** True when this profile is the connected account itself (Unipile's
   * `is_self === 1`). Connectors should still surface this profile as a
   * participant so message-sender lookups by `id` succeed, but skip it
   * when building the chat's contact list (the user is implicit). */
  isSelf: boolean;
  /** LinkedIn public identifier slug (`linkedin.com/in/<slug>`). May be null
   * when the member's profile is restricted. */
  publicIdentifier: string | null;
  fullName: string;
  headline: string | null;
  email: string | null;
  pictureUrl: string | null;
  /** `https://www.linkedin.com/in/<slug>/` when publicIdentifier is set,
   * otherwise null. */
  url: string | null;
};

export type LinkedInAttachment = {
  id: string;
  kind: "image" | "video" | "audio" | "file" | "other";
  name: string | null;
  url: string;
  contentType: string | null;
  byteSize: number | null;
};

export type LinkedInMessage = {
  /** Unipile message id (opaque). */
  id: string;
  /** Unipile chat id this message belongs to. */
  chatId: string;
  /** Provider id of the sender. */
  senderId: string;
  /** True iff the sender is the connected account. */
  sentByMe: boolean;
  sentAt: Date;
  /** Plain-text body (Unipile returns the canonical text form). */
  text: string;
  attachments: LinkedInAttachment[];
};

export type LinkedInChat = {
  id: string;
  title: string | null;
  isGroup: boolean;
  participants: LinkedInProfile[];
  lastMessagePreview: string | null;
  lastActivityAt: Date;
  unreadCount: number;
  archived: boolean;
  /** `https://www.linkedin.com/messaging/thread/<id>/`. */
  url: string;
};

export type LinkedInChatPage = {
  chats: LinkedInChat[];
  /** Pass back as `before` to fetch the next page; null when no more pages. */
  nextCursor: string | null;
};

export type LinkedInMessagePage = {
  messages: LinkedInMessage[];
  nextCursor: string | null;
};

export type LinkedInInvitation = {
  /** Unipile invitation id. */
  id: string;
  /** Token required to accept/ignore the invitation. */
  sharedSecret: string;
  inviter: LinkedInProfile;
  message: string | null;
  sentAt: Date;
};

export type LinkedInInvitationPage = {
  invitations: LinkedInInvitation[];
  nextCursor: string | null;
};

export type LinkedInRelationPage = {
  relations: LinkedInProfile[];
  nextCursor: string | null;
};
