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
import { UnipileApiError, UnipileClient } from "./client";
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
    return this.withAccount(params.channelId, async () => {
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
    });
  }

  async getChat(params: { channelId: string; chatId: string }): Promise<ChatThread> {
    return this.withAccount(params.channelId, async () => {
      // v2 embeds participants in the chat payload — no separate attendees call.
      const raw = await this.client.getChat({ accountId: params.channelId, chatId: params.chatId });
      return normalizeChat(raw, this.provider);
    });
  }

  async listMessages(params: { channelId: string; chatId: string; cursor?: string | null; limit?: number; since?: Date }): Promise<ChatMessagePage> {
    return this.withAccount(params.channelId, async () => {
      const offset = params.cursor ? Number(params.cursor) : 0;
      const result = await this.client.listMessages({ accountId: params.channelId, chatId: params.chatId, offset, limit: params.limit });
      const messages = result.data.map(normalizeMessage).filter((m) => !params.since || m.sentAt >= params.since);
      const nextCursor = result.has_more ? String(offset + result.data.length) : null;
      return { messages, nextCursor };
    });
  }

  async sendMessage(params: { channelId: string; chatId: string; text: string; attachments?: Array<{ buffer: Uint8Array; filename: string; mimeType: string }> }): Promise<ChatMessage> {
    return this.withAccount(params.channelId, async () => {
      const result = params.attachments && params.attachments.length > 0
        ? await this.client.sendMessageMultipart({ accountId: params.channelId, chatId: params.chatId, text: params.text, attachments: params.attachments })
        : await this.client.sendMessage({ accountId: params.channelId, chatId: params.chatId, text: params.text });
      // v2 send echoes only { message_id }; synthesize the sent ChatMessage.
      return this.sentMessage(result.message_id, params.chatId, params.text);
    });
  }

  async downloadAttachment(params: { channelId: string; messageId: string; attachmentId: string }): Promise<{ body: ReadableStream; mimeType: string; fileName?: string }> {
    return this.withAccount(params.channelId, async () => {
      const response = await this.client.downloadAttachmentRaw({ accountId: params.channelId, messageId: params.messageId, attachmentId: params.attachmentId });
      const contentType = response.headers.get("content-type") ?? "application/octet-stream";
      const mimeType = contentType.split(";")[0]?.trim() ?? "application/octet-stream";
      const disposition = response.headers.get("content-disposition") ?? "";
      const m = disposition.match(/filename\*?=(?:UTF-8'')?["']?([^"';\r\n]+)["']?/i);
      const fileName = m?.[1] ? decodeURIComponent(m[1].trim()) : undefined;
      return { body: response.body as ReadableStream, mimeType, fileName };
    });
  }

  async setChatRead(params: { channelId: string; chatId: string; read: boolean }): Promise<void> {
    return this.withAccount(params.channelId, () =>
      this.client.setChatRead({ accountId: params.channelId, chatId: params.chatId, read: params.read })
    );
  }

  async setMessageReaction(params: { channelId: string; chatId: string; messageId: string; reaction: string }): Promise<void> {
    return this.withAccount(params.channelId, () =>
      this.client.addMessageReaction({ accountId: params.channelId, chatId: params.chatId, messageId: params.messageId, reaction: params.reaction })
    );
  }

  async clearMessageReaction(params: { channelId: string; chatId: string; messageId: string }): Promise<void> {
    return this.withAccount(params.channelId, () =>
      this.client.removeMessageReaction({ accountId: params.channelId, chatId: params.chatId, messageId: params.messageId })
    );
  }

  async startChat(params: { channelId: string; recipientIds: string[]; text: string; title?: string | null }): Promise<{ chatId: string; message: ChatMessage }> {
    return this.withAccount(params.channelId, async () => {
      // v2 chats/send echoes { chat_id, message_id }; synthesize the sent message.
      const result = await this.client.startChat({ accountId: params.channelId, attendeeProviderIds: params.recipientIds, text: params.text, title: params.title ?? null });
      return { chatId: result.chat_id, message: this.sentMessage(result.message_id, result.chat_id, params.text) };
    });
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
    return this.withAccount(params.channelId, async () => {
      const raw = await this.client.getAttendee({ accountId: params.channelId, providerId: params.profileId });
      return normalizeProfile(raw, this.provider);
    });
  }

  // Default: free-form recipients unsupported (LinkedIn closed roster). Overridden by WhatsApp/Instagram.
  async resolveRecipient(_params: { channelId: string; address: string }): Promise<string | null> {
    return null;
  }

  /**
   * Assert the channel is enabled with stored credentials, then run `fn` and, if
   * Unipile rejects the call as unauthenticated (401/403), flag the connection
   * for re-auth so the app prompts "Reconnect". Without this, a credential that
   * no longer authenticates (e.g. a pre-v2 account id under v2, or a revoked
   * account) would just throw on every sync and break the connection silently.
   */
  protected async withAccount<T>(channelId: string, fn: () => Promise<T>): Promise<T> {
    await this.assertAccount(channelId);
    try {
      return await fn();
    } catch (e) {
      if (e instanceof UnipileApiError && (e.status === 401 || e.status === 403)) {
        const cfg = await this.store.get<{ enabledBy?: string }>(`channel_config:${this.provider}:${channelId}`);
        if (cfg?.enabledBy) {
          await this.flagChannelNeedsReauth(channelId, cfg.enabledBy, "auth_rejected");
        }
      }
      throw e;
    }
  }

  protected async assertAccount(channelId: string): Promise<void> {
    const cfg = await this.store.get<{ enabled?: boolean; enabledBy?: string }>(`channel_config:${this.provider}:${channelId}`);
    if (!cfg?.enabledBy) throw new Error(`${this.provider} channel ${channelId} is not enabled by any actor`);
    const token = await this.store.get<StoredTokenData>(`auth_token:${this.provider}:${cfg.enabledBy}`);
    if (!token?.access_token) {
      // The stored account credential is gone (a lost saveAuth write, a
      // same-environment orphan sweep that deleted the account, or a pre-v2
      // account id that no longer authenticates under v2). In v2 each
      // environment has its own Unipile workspace, so a cross-environment
      // "dev/prod pool reclaim" can no longer be a cause. Flag the connection
      // for re-auth so the app prompts "Reconnect" — otherwise the
      // initial-sync backfill dies here
      // before calling channelSyncCompleted and the tile spins on "Syncing"
      // forever. Best-effort (flagConnectionNeedsReauth never throws).
      await this.flagChannelNeedsReauth(channelId, cfg.enabledBy, "token_missing");
      throw new Error(`${this.provider} channel ${channelId} has no stored credentials — reconnect`);
    }
  }

  /**
   * Flag this channel's connection for re-auth. Split out so the DB write lives
   * in one shared helper ({@link flagConnectionNeedsReauth}) and so
   * `assertAccount` stays unit-testable without a database.
   */
  protected async flagChannelNeedsReauth(
    channelId: string,
    actorId: string,
    trigger: "token_missing" | "auth_rejected" = "token_missing"
  ): Promise<void> {
    await flagConnectionNeedsReauth(this.options.db, this.options.env, {
      twistInstanceId: this.options.twistInstanceId,
      provider: this.provider,
      actorId,
      details: {
        trigger,
        reason:
          trigger === "auth_rejected"
            ? `${this.provider} channel ${channelId} was rejected by Unipile (401/403) — credential no longer authenticates`
            : `${this.provider} channel ${channelId} has no stored credentials`,
      },
    });
  }
}
