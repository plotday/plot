import { ITool } from "@plotday/twister";

/**
 * Provider-neutral messaging types shared by the LinkedIn, WhatsApp, and
 * Instagram connectors. Intentionally Plot-flavoured, not Unipile-flavoured:
 * the concrete tools in workers/api map Unipile wire shapes onto these.
 */

export type ChatProfile = {
  /** Provider-side id (Unipile `provider_id`). */
  id: string;
  /** True when this profile is the connected account itself. */
  isSelf: boolean;
  /** Display name. */
  name: string;
  /** Username / public slug: LinkedIn public_identifier, IG @username, or null. */
  handle: string | null;
  /** Secondary line: LinkedIn headline, WhatsApp status, etc. */
  subtitle: string | null;
  email: string | null;
  /** E.164-ish phone when known (WhatsApp). */
  phone: string | null;
  pictureUrl: string | null;
  /** Canonical web profile URL when derivable, else null. */
  profileUrl: string | null;
};

export type ChatAttachment = {
  id: string;
  kind: "image" | "video" | "audio" | "file" | "other";
  name: string | null;
  url: string;
  contentType: string | null;
  byteSize: number | null;
};

export type ChatMessageReaction = {
  value: string;
  senderId: string;
  sentByMe: boolean;
};

export type ChatMessage = {
  id: string;
  chatId: string;
  senderId: string;
  /**
   * The sender's profile when the provider embeds it on the message. WhatsApp
   * group chats return no participant roster on the chat, so `senderId` matches
   * no participant — this per-message sender is then the only source of the
   * author's real name/avatar. Null when the provider omits it.
   */
  sender: ChatProfile | null;
  sentByMe: boolean;
  /** Non-null for synthetic events (reactions, renames, calls); connectors skip these. */
  eventType: string | null;
  sentAt: Date;
  text: string;
  attachments: ChatAttachment[];
  reactions: ChatMessageReaction[];
};

export type ChatThread = {
  id: string;
  title: string | null;
  isGroup: boolean;
  participants: ChatProfile[];
  lastMessagePreview: string | null;
  lastActivityAt: Date;
  unreadCount: number;
  archived: boolean;
  /**
   * Provider folder/bucket when applicable. Instagram surfaces message
   * requests via a non-inbox folder (e.g. "REQUESTS"); null when unknown or
   * the platform has no folder concept.
   */
  folder: string | null;
  url: string | null;
};

export type ChatThreadPage = { chats: ChatThread[]; nextCursor: string | null };
export type ChatMessagePage = { messages: ChatMessage[]; nextCursor: string | null };

/**
 * Common messaging surface every Unipile provider tool implements. Concrete
 * impls live in `workers/api/src/twist/tools/unipile/*`. Provider-specific
 * extras (LinkedIn invitations/relations, IG message requests) are declared on
 * the per-provider subclasses.
 */
export abstract class UnipileMessaging extends ITool {
  // Subclasses set their own static toolId (e.g. "WhatsAppMessaging").

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listChats(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<ChatThreadPage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getChat(params: { channelId: string; chatId: string }): Promise<ChatThread>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listMessages(params: {
    channelId: string;
    chatId: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<ChatMessagePage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract sendMessage(params: {
    channelId: string;
    chatId: string;
    text: string;
    attachments?: Array<{ buffer: Uint8Array; filename: string; mimeType: string }>;
  }): Promise<ChatMessage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract downloadAttachment(params: {
    channelId: string;
    messageId: string;
    attachmentId: string;
  }): Promise<{ body: ReadableStream; mimeType: string; fileName?: string }>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract setChatRead(params: { channelId: string; chatId: string; read: boolean }): Promise<void>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract setMessageReaction(params: {
    channelId: string;
    chatId: string;
    messageId: string;
    reaction: string;
  }): Promise<void>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract clearMessageReaction(params: { channelId: string; chatId: string; messageId: string }): Promise<void>;

  /**
   * Start a new chat (1:1 or group) and send the first message. Provider ids
   * are the platform's attendee ids (LinkedIn URN, WhatsApp JID, IG user id).
   * `title` names a group; ignored for 1:1.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract startChat(params: {
    channelId: string;
    recipientIds: string[];
    text: string;
    title?: string | null;
  }): Promise<{ chatId: string; message: ChatMessage }>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getProfile(params: { channelId: string; profileId: string }): Promise<ChatProfile>;

  /**
   * The connected account's OWN provider profile (`isSelf: true`), fetched from
   * the provider's `users/me` route. Its `id` is the same provider id the
   * account was bound to at connect time, so authoring the connected user's
   * own ("sent-by-me") messages with it dedups onto the owner's existing
   * contact — providers return an empty/absent `sender_id` on own messages, so
   * the per-message id cannot be relied on for that attribution. Cached per
   * channel for the lifetime of the tool instance.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getOwnProfile(params: { channelId: string }): Promise<ChatProfile>;

  /**
   * Resolve a free-form typed address (phone for WhatsApp, @username for
   * Instagram) to a provider attendee id usable in `startChat`. Returns null
   * when the address can't be resolved. Default (LinkedIn: closed roster,
   * compose targets contacts) returns null.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract resolveRecipient(params: { channelId: string; address: string }): Promise<string | null>;
}
