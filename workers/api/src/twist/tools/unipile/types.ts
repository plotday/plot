/**
 * Internal Unipile API **v2** response shapes. These never leak past
 * normalize.ts — every caller of the UnipileClient receives Plot-shaped
 * values from `libs/unipile/src/types.ts` instead.
 *
 * v2 conventions (confirmed live 2026-06-24 against the mock account):
 *   - Single host `https://api.unipile.com`, version prefix `/v2` (no DSN).
 *   - List responses: `{ object, data: T[], has_more }` with `?limit&offset`.
 *   - IDs are provider ids; Unipile-generated ids are prefixed (`acc_`, `we_`).
 */

export type UnipileAccountSource = "LINKEDIN" | "WHATSAPP" | "INSTAGRAM";

/** Generic v2 list envelope. */
export type UnipileList<T> = {
  object: string;
  data: T[];
  has_more: boolean;
};

export type UnipileAccount = {
  object: "Account";
  id: string; // acc_… — opaque
  /** Provider-side user id (the connected member). v2's identity field. */
  user_id: string;
  provider: string; // "LINKEDIN" | "WHATSAPP" | "INSTAGRAM" | "mock"
  status: string; // e.g. "running"
  created_at: string;
  name?: string;
  application_id?: string;
  metadata?: Record<string, unknown>;
};

export type UnipileAccountList = UnipileList<UnipileAccount>;

/**
 * v2 user object. The embedded chat participant (`object: "User"`) and the
 * full profile from `users/me` / `users/:id` (`object: "UserProfile"`) share
 * these fields; UserProfile adds bio/location/counts which we don't need.
 */
export type UnipileUser = {
  object: "User" | "UserProfile";
  id: string; // provider id
  type?: string;
  display_name: string | null;
  public_identifier: string | null;
  first_name?: string | null;
  last_name?: string | null;
  public_picture_url?: string | null;
  bio?: string | null;
  /** Headline-equivalent on relation/profile payloads (top-level, not nested). */
  description?: string | null;
  /** Provider profile URL when supplied (e.g. linkedin.com/in/…). */
  profile_url?: string | null;
  specifics?: {
    network_distance?: string;
    email?: string;
    headline?: string;
    /** WhatsApp phone, when present. */
    phone?: string;
  };
};

/** Group-chat participant wrapper: `is_self`/`is_admin` + the embedded user. */
export type UnipileGroupParticipant = {
  object: "GroupParticipant";
  is_self: boolean;
  is_admin?: boolean;
  user: UnipileUser;
};

export type UnipileChat = {
  object: "Chat";
  id: string; // provider thread id
  account_id?: string;
  provider: string;
  name: string | null;
  type: string; // "1to1" | "group" | "channel"
  is_group: boolean;
  is_1to1?: boolean;
  is_archived: boolean;
  unread_count: number;
  last_message_timestamp: string;
  folders?: string[];
  /** Group chats embed participants here. */
  participants?: UnipileGroupParticipant[];
  /** 1:1 chats embed the other party here (self is implicit). */
  user?: UnipileUser;
  user_id?: string;
};

export type UnipileChatList = UnipileList<UnipileChat>;

/** v2 reaction aggregate entry. */
export type UnipileReactionCounter = {
  value: string;
  count?: number;
  /** True iff the connected account is among the reactors. */
  reacted?: boolean;
};

export type UnipileMessage = {
  object: "Message";
  id: string; // provider message id
  chat_id: string;
  sender_id: string;
  timestamp: string;
  is_sender: boolean;
  is_seen?: boolean;
  is_event?: boolean;
  /** Sub-type for event messages (e.g. "reaction", "group-create"). */
  event_type?: string;
  text: string | null;
  attachments?: UnipileAttachment[];
  reactions_counter?: UnipileReactionCounter[];
  sender?: UnipileUser;
};

export type UnipileAttachment = {
  id: string;
  type: "img" | "video" | "audio" | "file" | "link" | "sticker" | string;
  url?: string;
  name?: string;
  mimetype?: string;
  file_size?: number;
};

export type UnipileMessageList = UnipileList<UnipileMessage>;

/** Echo returned by `POST .../messages/send` — not a full Message. */
export type UnipileSendResult = {
  object?: string; // "MessageSent"
  message_id: string;
};

/** Echo returned by `POST .../chats/send` (start chat). */
export type UnipileChatStarted = {
  object?: string; // "ChatStarted"
  chat_id: string;
  message_id: string;
};

export type UnipileHostedAuthLink = {
  object: "HostedAuthURL" | string;
  url: string;
};

export type UnipileWebhook = {
  object: "WebhookEndpoint";
  id: string; // we_…
  url: string;
  trigger_events?: string[];
  /** Per-endpoint signing secret (wes_…) returned at creation. */
  secret?: string;
  enabled?: boolean;
  account_ids?: string[];
};

export type UnipileWebhookList = UnipileList<UnipileWebhook>;

/**
 * LinkedIn invitation received — `GET /v2/:acc/users/me/relation-requests?type=received`.
 * v2 shape (confirmed live): the inviter is embedded under `user`. There is no
 * `shared_secret` in v2 (accept/ignore is keyed on the request id).
 */
export type UnipileInvitation = {
  object?: string;
  id: string;
  type?: string;
  created_at?: string;
  message?: string | null;
  user: UnipileUser;
};

/** v2 relation/invitation lists are cursor-paginated: `{ data, next_cursor }`. */
export type UnipileInvitationList = {
  data: UnipileInvitation[];
  next_cursor?: string | null;
};

/**
 * LinkedIn 1st-degree relation — `GET /v2/:acc/users/me/relations`.
 * v2 shape (confirmed live): the profile is embedded under `user`.
 */
export type UnipileRelation = {
  object?: string;
  id: string;
  user: UnipileUser;
  created_at?: string;
};

export type UnipileRelationList = {
  data: UnipileRelation[];
  next_cursor?: string | null;
};
