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
  seen: 0 | 1;
  text: string | null;
  attachments?: UnipileAttachment[];
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

export type UnipileInvitation = {
  object: "Invitation";
  id: string;
  inviter: UnipileAttendee;
  message: string | null;
  shared_secret: string;
  created_at: string;
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
