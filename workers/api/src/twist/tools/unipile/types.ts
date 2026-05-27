/**
 * Internal Unipile API response shapes. These never leak past
 * normalize.ts — every caller of the UnipileClient receives Plot-shaped
 * values from `libs/unipile/src/types.ts` instead.
 */

export type UnipileAccountSource =
  | "LINKEDIN"
  | "WHATSAPP"
  | "INSTAGRAM";

export type UnipileAccount = {
  object: "Account";
  id: string;
  type: UnipileAccountSource;
  created_at: string;
  connection_params?: {
    im?: {
      id?: string;
      username?: string;
    };
  };
  sources: {
    id: string;
    status: "OK" | "ERROR" | "STOPPED" | "CREDENTIALS";
  }[];
  name?: string;
};

export type UnipileChat = {
  object: "Chat";
  id: string;
  account_id: string;
  account_type: UnipileAccountSource;
  provider_id: string;
  name: string | null;
  type: 0 | 1; // 0 = 1:1, 1 = group
  timestamp: string;
  unread_count: number;
  archived: 0 | 1;
  read_only: 0 | 1;
  muted_until: string | null;
  attendee_provider_id: string | null;
};

export type UnipileChatList = {
  object: "ChatList";
  items: UnipileChat[];
  cursor: string | null;
};

export type UnipileMessageReaction = {
  /** Reaction emoji (Unicode). */
  value: string;
  /** Provider id of the reactor. */
  sender_id: string;
  /** True iff the reactor is the connected account. */
  is_sender: boolean;
};

export type UnipileMessage = {
  object: "Message";
  id: string;
  chat_id: string;
  chat_provider_id: string;
  provider_id: string;
  sender_id: string;
  sender_attendee_id: string;
  timestamp: string;
  is_sender: 0 | 1;
  is_event: 0 | 1;
  /**
   * Sub-type for `is_event === 1` messages. Unipile uses small string
   * tokens like `"reaction"`, `"group-create"`, `"group-rename"`,
   * `"call-missed-voice"`. Absent on regular chat messages.
   */
  event_type?: string;
  seen: 0 | 1;
  text: string | null;
  attachments?: UnipileAttachment[];
  /** Aggregate of every reactor's current reaction. */
  reactions?: UnipileMessageReaction[];
};

export type UnipileAttachment = {
  id: string;
  type:
    | "img"
    | "video"
    | "audio"
    | "file"
    | "link"
    | "sticker"
    | string;
  url?: string;
  name?: string;
  mimetype?: string;
  file_size?: number;
};

export type UnipileMessageList = {
  object: "MessageList";
  items: UnipileMessage[];
  cursor: string | null;
};

export type UnipileAttendee = {
  object: "Attendee";
  provider_id: string;
  name: string | null;
  profile_url: string | null;
  picture_url: string | null;
  is_self: 0 | 1;
  specifics?: {
    public_identifier?: string;
    headline?: string;
    email?: string;
  };
};

export type UnipileAttendeeList = {
  object: "AttendeeList";
  items: UnipileAttendee[];
  cursor: string | null;
};

/**
 * Per-invitation inviter sub-object. Unipile uses a flat snake_case
 * `inviter_*` prefix here instead of the `UnipileAttendee` shape — fields
 * are mostly the same data but renamed and not nested under `specifics`.
 */
export type UnipileInviter = {
  inviter_id: string;
  inviter_name: string | null;
  inviter_public_identifier: string | null;
  inviter_description: string | null;
  inviter_profile_picture_url: string | null;
};

export type UnipileInvitation = {
  object: "InvitationReceived";
  id: string;
  parsed_datetime: string;
  invitation_text: string | null;
  inviter: UnipileInviter;
  specifics: {
    provider: string;
    shared_secret: string;
  };
};

export type UnipileInvitationList = {
  object: "InvitationList";
  items: UnipileInvitation[];
  cursor: string | null;
};

export type UnipileHostedAuthLink = {
  object: "HostedAuthURL";
  url: string;
};

export type UnipileWebhookSource =
  | "messaging"
  | "account_status"
  | "users"
  | "email_tracking"
  | "mailing"
  | "email";

export type UnipileWebhook = {
  object: "Webhook";
  id: string;
  source: UnipileWebhookSource;
  request_url: string;
  headers?: { key: string; value: string }[];
  events?: string[] | null;
};

/**
 * Unipile relation (1st-degree LinkedIn connection). Shape comes from
 * `GET /users/relations`. Unlike `UnipileAttendee` this is flat (no
 * `specifics` nesting) and uses `member_id` rather than `provider_id`.
 * See https://github.com/unipile/unipile-node-sdk
 * (src/users/ressource.types.ts → LinkedinUserRelationSchema).
 */
export type UnipileRelation = {
  object: "UserRelation";
  member_id: string;
  member_urn: string;
  connection_urn: string;
  first_name: string;
  last_name: string;
  headline: string;
  public_identifier: string;
  public_profile_url: string;
  profile_picture_url?: string;
  created_at: number;
};

export type UnipileRelationList = {
  object: "UserRelationsList";
  items: UnipileRelation[];
  cursor: string | null;
};
