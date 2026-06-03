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
    const result = await this.client.listChats({ accountId: params.channelId, cursor: params.cursor ?? null, limit: params.limit });
    const chats: ChatThread[] = [];
    for (const raw of result.items) {
      const attendees = await this.client.listChatAttendees({ chatId: raw.id });
      const chat = normalizeChat(raw, attendees.items, this.provider);
      if (params.since && chat.lastActivityAt < params.since) continue;
      chats.push(chat);
    }
    return { chats, nextCursor: result.cursor };
  }

  async getChat(params: { channelId: string; chatId: string }): Promise<ChatThread> {
    await this.assertAccount(params.channelId);
    const [raw, attendees] = await Promise.all([
      this.client.getChat({ chatId: params.chatId }),
      this.client.listChatAttendees({ chatId: params.chatId }),
    ]);
    return normalizeChat(raw, attendees.items, this.provider);
  }

  async listMessages(params: { channelId: string; chatId: string; cursor?: string | null; limit?: number; since?: Date }): Promise<ChatMessagePage> {
    await this.assertAccount(params.channelId);
    const result = await this.client.listMessages({ chatId: params.chatId, cursor: params.cursor ?? null, limit: params.limit });
    const messages = result.items.map(normalizeMessage).filter((m) => !params.since || m.sentAt >= params.since);
    return { messages, nextCursor: result.cursor };
  }

  async sendMessage(params: { channelId: string; chatId: string; text: string; attachments?: Array<{ buffer: Uint8Array; filename: string; mimeType: string }> }): Promise<ChatMessage> {
    await this.assertAccount(params.channelId);
    const raw = params.attachments && params.attachments.length > 0
      ? await this.client.sendMessageMultipart({ chatId: params.chatId, text: params.text, attachments: params.attachments })
      : await this.client.sendMessage({ chatId: params.chatId, text: params.text });
    return normalizeMessage(raw);
  }

  async downloadAttachment(params: { channelId: string; messageId: string; attachmentId: string }): Promise<{ body: ReadableStream; mimeType: string; fileName?: string }> {
    await this.assertAccount(params.channelId);
    const response = await this.client.downloadAttachmentRaw({ messageId: params.messageId, attachmentId: params.attachmentId });
    const contentType = response.headers.get("content-type") ?? "application/octet-stream";
    const mimeType = contentType.split(";")[0]?.trim() ?? "application/octet-stream";
    const disposition = response.headers.get("content-disposition") ?? "";
    const m = disposition.match(/filename\*?=(?:UTF-8'')?["']?([^"';\r\n]+)["']?/i);
    const fileName = m?.[1] ? decodeURIComponent(m[1].trim()) : undefined;
    return { body: response.body as ReadableStream, mimeType, fileName };
  }

  async setChatRead(params: { channelId: string; chatId: string; read: boolean }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.setChatRead({ chatId: params.chatId, read: params.read });
  }

  async setMessageReaction(params: { channelId: string; messageId: string; reaction: string }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.addMessageReaction({ messageId: params.messageId, reaction: params.reaction });
  }

  async clearMessageReaction(params: { channelId: string; messageId: string }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.removeMessageReaction({ messageId: params.messageId });
  }

  async startChat(params: { channelId: string; recipientIds: string[]; text: string; title?: string | null }): Promise<{ chatId: string; message: ChatMessage }> {
    await this.assertAccount(params.channelId);
    const raw = await this.client.startChat({ accountId: params.channelId, attendeeProviderIds: params.recipientIds, text: params.text, title: params.title ?? null });
    const message = normalizeMessage(raw);
    return { chatId: message.chatId, message };
  }

  async getProfile(params: { channelId: string; profileId: string }): Promise<ChatProfile> {
    await this.assertAccount(params.channelId);
    const raw = await this.client.getAttendee({ providerId: params.profileId });
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
    if (!token?.access_token) throw new Error(`${this.provider} channel ${channelId} has no stored credentials — reconnect`);
  }
}
