import { ITool } from "@plotday/twister";

import type {
  LinkedInChat,
  LinkedInChatPage,
  LinkedInInvitationPage,
  LinkedInMessage,
  LinkedInMessagePage,
  LinkedInProfile,
  LinkedInRelationPage,
} from "./types";

/**
 * Built-in tool for calling a connected LinkedIn account's messaging and
 * invitation APIs.
 *
 * Implementation lives in `workers/api/src/twist/tools/unipile/linkedin.ts`
 * and routes through Unipile's hosted API. The connector never sees that
 * detail — methods take provider-flavoured arguments (chatId, invitationId)
 * and return provider-flavoured shapes.
 */
export abstract class LinkedInMessaging extends ITool {
  static readonly toolId = "LinkedInMessaging";

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listChats(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<LinkedInChatPage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getChat(params: {
    channelId: string;
    chatId: string;
  }): Promise<LinkedInChat>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listMessages(params: {
    channelId: string;
    chatId: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<LinkedInMessagePage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract sendMessage(params: {
    channelId: string;
    chatId: string;
    text: string;
  }): Promise<LinkedInMessage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract setChatRead(params: {
    channelId: string;
    chatId: string;
    read: boolean;
  }): Promise<void>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listReceivedInvitations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<LinkedInInvitationPage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listRelations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<LinkedInRelationPage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getProfile(params: {
    channelId: string;
    profileId: string;
  }): Promise<LinkedInProfile>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract acceptInvitation(params: {
    channelId: string;
    invitationId: string;
    sharedSecret: string;
  }): Promise<void>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract ignoreInvitation(params: {
    channelId: string;
    invitationId: string;
    sharedSecret: string;
  }): Promise<void>;

  /**
   * Start a new LinkedIn DM conversation (1:1 or group) and send the first
   * message atomically.
   *
   * - **1:1**: pass exactly one LinkedIn provider id in `recipientIds`.
   * - **Group**: pass two or more LinkedIn provider ids in `recipientIds`.
   *
   * If a 1:1 conversation with the recipient already exists, Unipile
   * reuses it. The returned `chatId` is stable and can be stored in
   * `thread.meta.chatId` for the existing `onNoteCreated` reply path.
   *
   * @param params.recipientIds - Provider-side LinkedIn member ids (Unipile
   *   `provider_id` values, which are LinkedIn URNs or numeric member ids
   *   depending on the Unipile version).
   * @param params.text - Message body (plain text).
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract startChat(params: {
    channelId: string;
    recipientIds: string[];
    text: string;
  }): Promise<{ chatId: string; message: LinkedInMessage }>;
}
