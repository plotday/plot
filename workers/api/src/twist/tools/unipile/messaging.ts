import type { Kysely } from "kysely";
import type {
  ChatProfile,
  ChatThread,
  ChatThreadPage,
  ChatMessage,
  ChatMessagePage,
  UnipileMessaging as IUnipileMessaging,
} from "@plotday/unipile";
import type { DB } from "../../../db-types";
import type { Bindings } from "../../../env";
import type { StoredTokenData } from "../../../provider";
import { flagConnectionNeedsReauth } from "../needs-reauth";
import { Store } from "../store";
import { Tool } from "../tool";
import { UnipileClient } from "./client";
import { normalizeChat, normalizeMessage, normalizeProfile } from "./normalize";

/**
 * Concrete base for all Unipile messaging tools. Routes through UnipileClient
 * and enforces auth per `provider`. Provider subclasses set `provider` and add
 * provider-specific methods (LinkedIn invitations, IG message requests).
 */
export abstract class UnipileMessagingTool extends Tool implements IUnipileMessaging {
  protected abstract readonly provider: string;
  protected store: Store;
  protected client: UnipileClient;

  constructor(
    protected options: { env: Bindings; db: Kysely<DB>; twistInstanceId: string; path: string[] }
  ) {
    super();
    this.store = new Store({
      path: options.path,
      storage: options.env.STORAGE,
      twistInstanceId: options.twistInstanceId,
    });
    this.client = new UnipileClient(options.env);
  }

  async listChats(params: { channelId: string; cursor?: string | null; limit?: number; since?: Date }): Promise<ChatThreadPage> {
    await this.assertAccount(params.channelId);
    // v2 paginates by offset; we carry it through the wrapper's string cursor.
    const offset = params.cursor ? Number(params.cursor) : 0;
    const result = await this.client.listChats({ accountId: params.channelId, offset, limit: params.limit });
    const chats: ChatThread[] = [];
    for (const raw of result.data) {
      const chat = normalizeChat(raw, this.provider);
      if (params.since && chat.lastActivityAt < params.since) continue;
      chats.push(chat);
    }
    const nextCursor = result.has_more ? String(offset + result.data.length) : null;
    return { chats, nextCursor };
  }

  async getChat(params: { channelId: string; chatId: string }): Promise<ChatThread> {
    await this.assertAccount(params.channelId);
    // v2 embeds participants in the chat payload — no separate attendees call.
    const raw = await this.client.getChat({ accountId: params.channelId, chatId: params.chatId });
    return normalizeChat(raw, this.provider);
  }

  async listMessages(params: { channelId: string; chatId: string; cursor?: string | null; limit?: number; since?: Date }): Promise<ChatMessagePage> {
    await this.assertAccount(params.channelId);
    const offset = params.cursor ? Number(params.cursor) : 0;
    const result = await this.client.listMessages({ accountId: params.channelId, chatId: params.chatId, offset, limit: params.limit });
    const messages = result.data.map(normalizeMessage).filter((m) => !params.since || m.sentAt >= params.since);
    const nextCursor = result.has_more ? String(offset + result.data.length) : null;
    return { messages, nextCursor };
  }

  async sendMessage(params: { channelId: string; chatId: string; text: string; attachments?: Array<{ buffer: Uint8Array; filename: string; mimeType: string }> }): Promise<ChatMessage> {
    await this.assertAccount(params.channelId);
    const result = params.attachments && params.attachments.length > 0
      ? await this.client.sendMessageMultipart({ accountId: params.channelId, chatId: params.chatId, text: params.text, attachments: params.attachments })
      : await this.client.sendMessage({ accountId: params.channelId, chatId: params.chatId, text: params.text });
    // v2 send echoes only { message_id }; synthesize the sent ChatMessage.
    return this.sentMessage(result.message_id, params.chatId, params.text);
  }

  async downloadAttachment(params: { channelId: string; messageId: string; attachmentId: string }): Promise<{ body: ReadableStream; mimeType: string; fileName?: string }> {
    await this.assertAccount(params.channelId);
    const response = await this.client.downloadAttachmentRaw({ accountId: params.channelId, messageId: params.messageId, attachmentId: params.attachmentId });
    const contentType = response.headers.get("content-type") ?? "application/octet-stream";
    const mimeType = contentType.split(";")[0]?.trim() ?? "application/octet-stream";
    const disposition = response.headers.get("content-disposition") ?? "";
    const m = disposition.match(/filename\*?=(?:UTF-8'')?["']?([^"';\r\n]+)["']?/i);
    const fileName = m?.[1] ? decodeURIComponent(m[1].trim()) : undefined;
    return { body: response.body as ReadableStream, mimeType, fileName };
  }

  async setChatRead(params: { channelId: string; chatId: string; read: boolean }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.setChatRead({ accountId: params.channelId, chatId: params.chatId, read: params.read });
  }

  async setMessageReaction(params: { channelId: string; chatId: string; messageId: string; reaction: string }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.addMessageReaction({ accountId: params.channelId, chatId: params.chatId, messageId: params.messageId, reaction: params.reaction });
  }

  async clearMessageReaction(params: { channelId: string; chatId: string; messageId: string }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.removeMessageReaction({ accountId: params.channelId, chatId: params.chatId, messageId: params.messageId });
  }

  async startChat(params: { channelId: string; recipientIds: string[]; text: string; title?: string | null }): Promise<{ chatId: string; message: ChatMessage }> {
    await this.assertAccount(params.channelId);
    // v2 chats/send echoes { chat_id, message_id }; synthesize the sent message.
    const result = await this.client.startChat({ accountId: params.channelId, attendeeProviderIds: params.recipientIds, text: params.text, title: params.title ?? null });
    return { chatId: result.chat_id, message: this.sentMessage(result.message_id, result.chat_id, params.text) };
  }

  /** Build the ChatMessage a connector records after sending, from the v2 send
   * echo (which carries only ids) plus the text we just sent. */
  private sentMessage(id: string, chatId: string, text: string): ChatMessage {
    return {
      id,
      chatId,
      senderId: "",
      sentByMe: true,
      eventType: null,
      sentAt: new Date(),
      text,
      attachments: [],
      reactions: [],
    };
  }

  async getProfile(params: { channelId: string; profileId: string }): Promise<ChatProfile> {
    await this.assertAccount(params.channelId);
    const raw = await this.client.getAttendee({ accountId: params.channelId, providerId: params.profileId });
    return normalizeProfile(raw, this.provider);
  }

  // Default: free-form recipients unsupported (LinkedIn closed roster). Overridden by WhatsApp/Instagram.
  async resolveRecipient(_params: { channelId: string; address: string }): Promise<string | null> {
    return null;
  }

  protected async assertAccount(channelId: string): Promise<void> {
    const cfg = await this.store.get<{ enabled?: boolean; enabledBy?: string }>(`channel_config:${this.provider}:${channelId}`);
    if (!cfg?.enabledBy) throw new Error(`${this.provider} channel ${channelId} is not enabled by any actor`);
    const token = await this.store.get<StoredTokenData>(`auth_token:${this.provider}:${cfg.enabledBy}`);
    if (!token?.access_token) {
      // The stored account credential is gone (lost saveAuth write, or a
      // dev/prod Unipile pool reclaim). Flag the connection for re-auth so the
      // app prompts "Reconnect" — otherwise the initial-sync backfill dies here
      // before calling channelSyncCompleted and the tile spins on "Syncing"
      // forever. Best-effort (flagConnectionNeedsReauth never throws).
      await this.flagChannelNeedsReauth(channelId, cfg.enabledBy);
      throw new Error(`${this.provider} channel ${channelId} has no stored credentials — reconnect`);
    }
  }

  /**
   * Flag this channel's connection for re-auth. Split out so the DB write lives
   * in one shared helper ({@link flagConnectionNeedsReauth}) and so
   * `assertAccount` stays unit-testable without a database.
   */
  protected async flagChannelNeedsReauth(channelId: string, actorId: string): Promise<void> {
    await flagConnectionNeedsReauth(this.options.db, this.options.env, {
      twistInstanceId: this.options.twistInstanceId,
      provider: this.provider,
      actorId,
      details: {
        trigger: "token_missing",
        reason: `${this.provider} channel ${channelId} has no stored credentials`,
      },
    });
  }
}
