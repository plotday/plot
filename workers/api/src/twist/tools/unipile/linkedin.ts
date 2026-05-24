import type { Kysely } from "kysely";

import type {
  LinkedInMessaging as ILinkedInMessaging,
  LinkedInChat,
  LinkedInChatPage,
  LinkedInInvitationPage,
  LinkedInMessage,
  LinkedInMessagePage,
  LinkedInProfile,
  LinkedInRelationPage,
} from "@plotday/unipile";

import type { DB } from "../../../db-types";
import type { Bindings } from "../../../env";
import type { StoredTokenData } from "../../../provider";
import { Store } from "../store";
import { Tool } from "../tool";
import { UnipileClient } from "./client";
import {
  normalizeChat,
  normalizeInvitation,
  normalizeMessage,
  normalizeProfile,
  normalizeRelation,
} from "./normalize";

/**
 * Concrete impl of the LinkedInMessaging built-in tool. Routes all calls
 * through Unipile via UnipileClient. The connector never sees Unipile
 * identifiers — it works with Plot-shaped {chatId, messageId, …} values
 * that happen to be Unipile ids.
 */
export class LinkedInMessaging extends Tool implements ILinkedInMessaging {
  private store: Store;
  private client: UnipileClient;

  constructor(
    private options: {
      env: Bindings;
      db: Kysely<DB>;
      twistInstanceId: string;
      path: string[];
    }
  ) {
    super();
    this.store = new Store({
      path: options.path,
      storage: options.env.STORAGE,
      twistInstanceId: options.twistInstanceId,
    });
    this.client = new UnipileClient(options.env);
  }

  async listChats(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<LinkedInChatPage> {
    await this.assertAccount(params.channelId);
    const result = await this.client.listChats({
      accountId: params.channelId,
      cursor: params.cursor ?? null,
      limit: params.limit,
    });
    const chats: LinkedInChat[] = [];
    for (const raw of result.items) {
      const attendees = await this.client.listChatAttendees({ chatId: raw.id });
      const chat = normalizeChat(raw, attendees.items);
      if (params.since && chat.lastActivityAt < params.since) continue;
      chats.push(chat);
    }
    return { chats, nextCursor: result.cursor };
  }

  async getChat(params: {
    channelId: string;
    chatId: string;
  }): Promise<LinkedInChat> {
    await this.assertAccount(params.channelId);
    const [raw, attendees] = await Promise.all([
      this.client.getChat({ chatId: params.chatId }),
      this.client.listChatAttendees({ chatId: params.chatId }),
    ]);
    return normalizeChat(raw, attendees.items);
  }

  async listMessages(params: {
    channelId: string;
    chatId: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<LinkedInMessagePage> {
    await this.assertAccount(params.channelId);
    const result = await this.client.listMessages({
      chatId: params.chatId,
      cursor: params.cursor ?? null,
      limit: params.limit,
    });
    const messages = result.items
      .map(normalizeMessage)
      .filter((m) => !params.since || m.sentAt >= params.since);
    return { messages, nextCursor: result.cursor };
  }

  async sendMessage(params: {
    channelId: string;
    chatId: string;
    text: string;
  }): Promise<LinkedInMessage> {
    await this.assertAccount(params.channelId);
    const raw = await this.client.sendMessage({
      chatId: params.chatId,
      text: params.text,
    });
    return normalizeMessage(raw);
  }

  async setChatRead(params: {
    channelId: string;
    chatId: string;
    read: boolean;
  }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.setChatRead({ chatId: params.chatId, read: params.read });
  }

  async listReceivedInvitations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<LinkedInInvitationPage> {
    await this.assertAccount(params.channelId);
    const result = await this.client.listReceivedInvitations({
      accountId: params.channelId,
      cursor: params.cursor ?? null,
      limit: params.limit,
    });
    return {
      invitations: result.items.map(normalizeInvitation),
      nextCursor: result.cursor,
    };
  }

  async listRelations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<LinkedInRelationPage> {
    await this.assertAccount(params.channelId);
    const result = await this.client.listRelations({
      accountId: params.channelId,
      cursor: params.cursor ?? null,
      limit: params.limit,
    });
    return {
      relations: result.items.map(normalizeRelation),
      nextCursor: result.cursor,
    };
  }

  async getProfile(params: {
    channelId: string;
    profileId: string;
  }): Promise<LinkedInProfile> {
    await this.assertAccount(params.channelId);
    const raw = await this.client.getAttendee({ providerId: params.profileId });
    return normalizeProfile(raw);
  }

  async acceptInvitation(params: {
    channelId: string;
    invitationId: string;
    sharedSecret: string;
  }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.acceptInvitation({
      invitationId: params.invitationId,
      sharedSecret: params.sharedSecret,
    });
  }

  async ignoreInvitation(params: {
    channelId: string;
    invitationId: string;
    sharedSecret: string;
  }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.ignoreInvitation({
      invitationId: params.invitationId,
      sharedSecret: params.sharedSecret,
    });
  }

  /**
   * Look up the stored token for the channel's account so call sites have
   * a single rejection point when the connection is missing or revoked.
   * The channelId IS the Unipile account_id (see Connector.getChannels).
   */
  private async assertAccount(channelId: string): Promise<void> {
    const channelConfigKey = `channel_config:linkedin:${channelId}`;
    const channelConfig = await this.store.get<{
      enabled?: boolean;
      enabledBy?: string;
    }>(channelConfigKey);
    if (!channelConfig?.enabledBy) {
      throw new Error(
        `LinkedIn channel ${channelId} is not enabled by any actor`
      );
    }
    const token = await this.store.get<StoredTokenData>(
      `auth_token:linkedin:${channelConfig.enabledBy}`
    );
    if (!token?.access_token) {
      throw new Error(
        `LinkedIn channel ${channelId} has no stored credentials — reconnect`
      );
    }
  }
}

export { normalizeProfile };
