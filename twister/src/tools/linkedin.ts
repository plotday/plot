import { ITool } from "..";

/**
 * Built-in tool for calling LinkedIn's internal messaging API on behalf of a
 * user.
 *
 * LinkedIn does not expose an OAuth scope for personal direct messages, so
 * Plot uses the same approach as Beeper, Unipile, and Kondo: the user's
 * authenticated session cookie (`li_at`) is captured by the Plot client and
 * used to call LinkedIn's internal "Voyager" web-client API.
 *
 * **Why this is a built-in tool and not a connector concern:**
 * - The Voyager wire format (request signing, CSRF token handling, the
 *   `x-li-*` header set, the pinned per-account user-agent) is hidden from
 *   the open-source connector — it lives entirely in the privileged
 *   server-side implementation.
 * - Rate limiting is shared across the fleet (one user's bursts can't
 *   trigger LinkedIn-side throttling for other users).
 * - The raw `li_at` cookie never crosses into the sandboxed twist runtime;
 *   the connector only sees the high-level methods on this tool.
 *
 * The tool is scoped to a single connection — instances are created per
 * channel-enabled connector and read their auth from the channel's stored
 * token. If LinkedIn returns an auth-style error (`401`, CSRF-stale `403`),
 * the tool automatically flags the connection for re-auth via
 * `integrations.markNeedsReauth` and throws `LinkedInAuthError`.
 *
 * @example
 * ```typescript
 * class LinkedInMessages extends Connector<LinkedInMessages> {
 *   readonly provider = AuthProvider.LinkedIn;
 *
 *   build(build: ToolBuilder) {
 *     return {
 *       linkedin: build(LinkedIn),
 *       integrations: build(Integrations),
 *     };
 *   }
 *
 *   async syncBatch(channelId: string, cursor: string | null) {
 *     const page = await this.tools.linkedin.listConversations({
 *       channelId,
 *       cursor,
 *       limit: 20,
 *     });
 *     // ...transform and saveLink each conversation...
 *     return page.nextCursor;
 *   }
 * }
 * ```
 */
export abstract class LinkedIn extends ITool {
  /**
   * List conversations from the user's LinkedIn inbox, newest first.
   *
   * Returns conversation summaries (title, last message preview, participant
   * URNs, unread count, last activity timestamp). Use `getMessages` to fetch
   * the full message history for a conversation.
   *
   * @param params.channelId - The channel resource ID (used to retrieve the
   *   user's stored cookie and rate-limit slot).
   * @param params.cursor - Pagination cursor from a previous call, or null
   *   to start from the most recent conversations.
   * @param params.limit - Max conversations to return (server may return
   *   fewer). Defaults to 20.
   * @param params.since - If provided, return only conversations with
   *   activity after this timestamp. Used for incremental sync.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listConversations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<LinkedInConversationPage>;

  /**
   * Fetch metadata for a single conversation by URN.
   *
   * Useful for refreshing participant lists, group titles, or unread counts
   * without re-fetching the entire message history.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getConversation(params: {
    channelId: string;
    conversationUrn: string;
  }): Promise<LinkedInConversation>;

  /**
   * Fetch messages from a conversation, newest first.
   *
   * @param params.cursor - Pagination cursor from a previous call, or null
   *   to start from the most recent messages.
   * @param params.limit - Max messages to return. Defaults to 20.
   * @param params.since - If provided, return only messages after this
   *   timestamp. Used for incremental sync.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getMessages(params: {
    channelId: string;
    conversationUrn: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<LinkedInMessagePage>;

  /**
   * Send a new message in a conversation.
   *
   * Returns the resulting message (with its assigned URN and server-side
   * timestamp), which the caller should use to establish the baseline hash
   * for `NoteWriteBackResult.externalContent`.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract sendMessage(params: {
    channelId: string;
    conversationUrn: string;
    text: string;
  }): Promise<LinkedInMessage>;

  /**
   * Mark a conversation as read or unread on LinkedIn.
   *
   * Called from the connector's `onThreadRead` to mirror the user's
   * read/unread state back to the LinkedIn web client.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract markConversationRead(params: {
    channelId: string;
    conversationUrn: string;
    read: boolean;
  }): Promise<void>;

  /**
   * List inbound connection invitations (with optional personal notes).
   *
   * Each invitation includes the inviter's profile, the personal note if
   * one was attached, and the invitation URN needed for accept/ignore.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listConnectionInvitations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<LinkedInInvitationPage>;

  /**
   * Accept an inbound connection invitation.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract acceptInvitation(params: {
    channelId: string;
    invitationUrn: string;
    sharedSecret: string;
  }): Promise<void>;

  /**
   * Ignore (decline) an inbound connection invitation.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract ignoreInvitation(params: {
    channelId: string;
    invitationUrn: string;
    sharedSecret: string;
  }): Promise<void>;

  /**
   * Start a new LinkedIn DM conversation (1:1 or group) and send the first
   * message atomically.
   *
   * - **1:1**: pass exactly one URN in `recipientUrns`.
   * - **Group**: pass two or more URNs in `recipientUrns`.
   *
   * If a 1:1 conversation with the recipient already exists, LinkedIn
   * typically reuses it. The returned `conversationUrn` is stable and
   * can be stored in `thread.meta.conversationUrn` so subsequent replies
   * via `onNoteCreated` work without extra lookup.
   *
   * @param params.recipientUrns - Profile URNs of the recipients
   *   (e.g. `urn:li:fsd_profile:AbC123`). The authenticated user is
   *   added implicitly by LinkedIn.
   * @param params.text - Message body (plain text). LinkedIn DMs have no
   *   subject line.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createConversation(params: {
    channelId: string;
    recipientUrns: string[];
    text: string;
  }): Promise<{ conversationUrn: string; message: LinkedInMessage }>;

  /**
   * Fetch a LinkedIn member's public profile by URN.
   *
   * Used to resolve participants in conversations to Plot contacts.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getProfile(params: {
    channelId: string;
    profileUrn: string;
  }): Promise<LinkedInProfile>;
}

/**
 * One LinkedIn conversation (1:1 or group) as returned by the LinkedIn tool.
 *
 * All fields use Plot-friendly shapes (Date instead of unix-ms numbers, plain
 * string URNs, no LinkedIn-internal nesting) so the open-source connector
 * never has to understand the Voyager wire format.
 */
export type LinkedInConversation = {
  /** URN like `urn:li:msg_conversation:(...)`. Stable for the lifetime of the conversation. */
  urn: string;
  /** Group title, or null for 1:1 conversations (caller derives the title from participants). */
  title: string | null;
  /** True if this is a multi-party (group) conversation. */
  isGroup: boolean;
  /** Profiles of all participants except the authenticated user. */
  participants: LinkedInProfile[];
  /** Most recent message preview (text only). */
  lastMessagePreview: string | null;
  /** When the most recent message was sent. */
  lastActivityAt: Date;
  /** Number of unread messages in this conversation. */
  unreadCount: number;
  /** True if the conversation has been archived on LinkedIn. */
  archived: boolean;
  /** URL the user can open in the LinkedIn web client. */
  url: string;
};

/** A page of conversations with optional cursor for the next page. */
export type LinkedInConversationPage = {
  conversations: LinkedInConversation[];
  nextCursor: string | null;
};

/**
 * One LinkedIn message inside a conversation.
 */
export type LinkedInMessage = {
  /** URN like `urn:li:msg_message:(...)`. Stable; use as the Plot note key. */
  urn: string;
  /** URN of the conversation this message belongs to. */
  conversationUrn: string;
  /** URN of the sender (or `urn:li:fsd_profile:<id>`). */
  senderUrn: string;
  /** True if this message was sent by the authenticated user. */
  sentByMe: boolean;
  /** Server-side send timestamp. */
  sentAt: Date;
  /** Plain-text message body. */
  text: string;
  /**
   * HTML body if the message contained rich formatting (links, mentions,
   * line breaks). Connectors should prefer this with `contentType: "html"`
   * so the server-side HTML→Markdown conversion preserves formatting.
   */
  html: string | null;
  /** Inline attachments (images, files). */
  attachments: LinkedInAttachment[];
};

/** A page of messages with optional cursor for the next page. */
export type LinkedInMessagePage = {
  messages: LinkedInMessage[];
  nextCursor: string | null;
};

/** Inline attachment on a message (image, file, sticker). */
export type LinkedInAttachment = {
  /** Stable URN for the attachment. */
  urn: string;
  /** Attachment kind. */
  kind: "image" | "file" | "video" | "audio" | "other";
  /** Display filename or caption. */
  name: string | null;
  /** Direct URL to the asset (may be CDN-signed and short-lived). */
  url: string;
  /** Content type when available. */
  contentType: string | null;
  /** Size in bytes when available. */
  byteSize: number | null;
};

/**
 * Minimal LinkedIn member profile.
 *
 * Only the fields needed to render a Plot contact are returned — full profile
 * details (positions, education, etc.) are intentionally out of scope. Use
 * `url` if a richer view is needed.
 */
export type LinkedInProfile = {
  /** URN like `urn:li:fsd_profile:<id>`. */
  urn: string;
  /** Public profile slug (the segment after `linkedin.com/in/`). */
  publicIdentifier: string | null;
  /** Combined first + last name. */
  fullName: string;
  /** Profile headline (e.g. "VP Eng at Acme"). */
  headline: string | null;
  /** Public email if exposed by LinkedIn (usually only your own profile). */
  email: string | null;
  /** URL to the highest-resolution profile picture LinkedIn returned. */
  pictureUrl: string | null;
  /** `https://www.linkedin.com/in/<publicIdentifier>` when available. */
  url: string | null;
};

/** Inbound connection invitation. */
export type LinkedInInvitation = {
  /** URN like `urn:li:fs_invitation:<id>`. Use as the Plot link source. */
  urn: string;
  /** Required by LinkedIn when accepting/ignoring. */
  sharedSecret: string;
  /** Profile of the person sending the invitation. */
  inviter: LinkedInProfile;
  /** Personal note attached to the invitation, if any. */
  message: string | null;
  /** When the invitation was sent. */
  sentAt: Date;
};

/** A page of invitations with optional cursor for the next page. */
export type LinkedInInvitationPage = {
  invitations: LinkedInInvitation[];
  nextCursor: string | null;
};
