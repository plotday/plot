import {
  Connector,
  type CreateLinkDraft,
  type NewLinkWithNotes,
  type NoteWriteBackResult,
  type ReactionCapabilities,
  type ToolBuilder,
} from "@plotday/twister";
import type { Action, Actor, Note, Thread } from "@plotday/twister/plot";
import { ActionType } from "@plotday/twister/plot";
import { Callbacks } from "@plotday/twister/tools/callbacks";
import { Files } from "@plotday/twister/tools/files";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";
import {
  backfillChats,
  buildLinkForChat,
  reconcilePerUserReaction,
  WhatsAppMessaging,
} from "@plotday/unipile";

const TYPE_CONVERSATION = "conversation";
const TYPE_GROUP = "group";
const PROVIDER_KEY = "whatsapp";

// Private connector — references the `"whatsapp"` auth provider value directly
// via a typecast since the OSS twister does not enumerate it in AuthProvider.
// The runtime stored value is still the string `"whatsapp"`.
const WHATSAPP_PROVIDER = "whatsapp" as AuthProvider;

export class WhatsApp extends Connector<WhatsApp> {
  static readonly PROVIDER = WHATSAPP_PROVIDER;
  static readonly SCOPES: string[] = [];
  static readonly handleReplies = true;

  readonly provider = WHATSAPP_PROVIDER;
  readonly scopes = WhatsApp.SCOPES;
  readonly access = [
    "Reads your WhatsApp messages",
    "Sends replies you write in Plot",
  ];
  readonly singleChannel = true;
  readonly reactionCapabilities: ReactionCapabilities = {
    mode: "open-unicode",
    customEmoji: "none",
  };
  readonly linkTypes = [
    {
      type: TYPE_CONVERSATION,
      label: "WhatsApp chat",
      sharingModel: "thread" as const,
      logo: "https://api.iconify.design/logos/whatsapp-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/whatsapp.svg",
      compose: { targets: "addresses" as const },
    },
    {
      type: TYPE_GROUP,
      label: "WhatsApp group",
      sharingModel: "thread" as const,
      logo: "https://api.iconify.design/logos/whatsapp-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/whatsapp.svg",
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      whatsapp: build(WhatsAppMessaging),
      network: build(Network, { urls: [] }),
      callbacks: build(Callbacks),
      tasks: build(Tasks),
      files: build(Files),
    };
  }

  override async getAccountName(
    auth: Authorization | null,
    _token: AuthToken | null
  ): Promise<string | null> {
    return auth?.actor.name ?? null;
  }

  async getChannels(
    auth: Authorization | null,
    token: AuthToken | null
  ): Promise<Channel[]> {
    if (!token?.token) return [];
    return [{ id: token.token, title: auth?.actor.name ?? "WhatsApp" }];
  }

  async onChannelEnabled(channel: Channel): Promise<void> {
    // Register the webhook callback first so new messages flow as soon as
    // the account is live.
    const cb = await this.tools.callbacks.createFromParent(
      this.onWebhookEvent,
      channel.id
    );
    await this.set(`webhook_callback_${channel.id}`, cb);

    // One-time backfill of existing chats. No relations crawl — WhatsApp has
    // no equivalent. No recurring poll — webhooks drive steady state.
    const task = await this.callback(this.backfill, channel.id);
    await this.runTask(task);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.clear(`webhook_callback_${channel.id}`);
  }

  /**
   * One-time backfill of existing WhatsApp conversations and groups.
   * `backfillChats` without `groupType` defaults to `"group"` for multi-person
   * chats (assembleGroupLink) and `"conversation"` for 1:1 (assembleConversationLink).
   */
  async backfill(channelId: string): Promise<void> {
    const { links } = await backfillChats({
      tool: this.tools.whatsapp,
      provider: PROVIDER_KEY,
      channelId,
      onAttachmentMessage: (id) =>
        this.set(`whatsapp:msg-channel:${id}`, channelId),
    });
    if (links.length > 0) {
      await this.tools.integrations.saveLinks(links);
    }
    await this.tools.integrations.channelSyncCompleted(channelId);
  }

  async onWebhookEvent(
    event: { kind: "message.received"; chatId: string; messageId: string },
    channelId: string
  ): Promise<void> {
    if (event.kind !== "message.received") return;
    const chat = await this.tools.whatsapp.getChat({
      channelId,
      chatId: event.chatId,
    });
    const link = await buildLinkForChat({
      tool: this.tools.whatsapp,
      provider: PROVIDER_KEY,
      channelId,
      chat,
      initialSync: false,
      onAttachmentMessage: (id) =>
        this.set(`whatsapp:msg-channel:${id}`, channelId),
    });
    if (link) await this.tools.integrations.saveLinks([link]);
  }

  override async onCreateLink(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    if (draft.type !== TYPE_CONVERSATION) return null;

    const body = (draft.noteContent ?? draft.title ?? "").trim();
    if (!body) {
      console.error("[whatsapp] onCreateLink: empty body");
      return null;
    }

    // Collect recipient ids from pre-resolved contacts (runtime-resolved
    // contact_external_account rows for "addresses" link types) PLUS any
    // free-form addresses the user typed (inviteEmails). Free-form addresses
    // are resolved via resolveRecipient (phone→JID).
    const ids: string[] = [];

    for (const r of draft.recipients ?? []) {
      ids.push(r.externalAccountId);
    }

    for (const addr of draft.inviteEmails ?? []) {
      const resolved = await this.tools.whatsapp.resolveRecipient({
        channelId: draft.channelId,
        address: addr,
      });
      if (resolved) ids.push(resolved);
    }

    if (ids.length === 0) {
      console.error("[whatsapp] onCreateLink: no recipients resolved");
      return null;
    }

    const isGroup = ids.length > 1;
    const { chatId, message } = await this.tools.whatsapp.startChat({
      channelId: draft.channelId,
      recipientIds: ids,
      text: body,
    });

    return {
      source: isGroup
        ? `whatsapp:chat:${chatId}`
        : `whatsapp:person:${ids[0]}`,
      sources: isGroup
        ? [`whatsapp:chat:${chatId}`]
        : [`whatsapp:person:${ids[0]}`, `whatsapp:chat:${chatId}`],
      type: TYPE_CONVERSATION,
      status: null,
      title: draft.title,
      created: message.sentAt,
      channelId: draft.channelId,
      meta: {
        syncProvider: PROVIDER_KEY,
        channelId: draft.channelId,
        chatId,
        ...(isGroup ? {} : { profileId: ids[0] }),
      },
    } satisfies NewLinkWithNotes;
  }

  override async onNoteCreated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    const meta = (thread.meta ?? {}) as Record<string, unknown>;
    const chatId = meta.chatId as string | undefined;
    const channelId = meta.channelId as string | undefined;
    if (!chatId || !channelId) return;

    const fileActions = (note.actions ?? []).filter(
      (a): a is Extract<Action, { type: typeof ActionType.file }> =>
        a.type === ActionType.file
    );

    const attachments: Array<{
      buffer: Uint8Array;
      filename: string;
      mimeType: string;
    }> = [];
    for (const a of fileActions) {
      try {
        const f = await this.tools.files.read(a.fileId);
        attachments.push({
          buffer: f.data,
          filename: f.fileName,
          mimeType: f.mimeType,
        });
      } catch (e) {
        console.error("WhatsApp attachment read failed", a.fileId, e);
      }
    }

    const sent = await this.tools.whatsapp.sendMessage({
      channelId,
      chatId,
      text: note.content ?? "",
      attachments: attachments.length > 0 ? attachments : undefined,
    });
    return { key: `message-${sent.id}`, externalContent: sent.text };
  }

  /**
   * Pushes a single emoji add/remove back to WhatsApp, attributed to the
   * reacting user (dispatched on their own connector instance via
   * `twist_instance_for_actor`). WhatsApp allows one open-unicode reaction per
   * user per message; we track the last-pushed emoji per user/message in
   * `reaction_sent:${messageId}` and reconcile via `reconcilePerUserReaction`.
   */
  override async onNoteReactionChanged(
    note: Note,
    thread: Thread,
    _actor: Actor,
    emoji: string,
    added: boolean
  ): Promise<void> {
    const meta = (thread.meta ?? {}) as Record<string, unknown>;
    const channelId = meta.channelId as string | undefined;
    if (!channelId) return;
    if (!note.key || !note.key.startsWith("message-")) return;
    const messageId = note.key.slice("message-".length);
    if (!messageId) return;

    const stateKey = `reaction_sent:${messageId}`;
    const lastSent = (await this.get<string>(stateKey)) ?? null;
    const decision = reconcilePerUserReaction(lastSent, emoji, added);
    if (decision.action === "none") return;

    try {
      if (decision.action === "set") {
        await this.tools.whatsapp.setMessageReaction({
          channelId,
          messageId,
          reaction: decision.emoji,
        });
        await this.set(stateKey, decision.emoji);
      } else {
        await this.tools.whatsapp.clearMessageReaction({ channelId, messageId });
        await this.clear(stateKey);
      }
    } catch (error) {
      console.warn(
        `WhatsApp reaction write-back failed for message ${messageId}`,
        error
      );
    }
  }

  override async onThreadRead(
    thread: Thread,
    _actor: Actor,
    unread: boolean
  ): Promise<void> {
    const meta = (thread.meta ?? {}) as Record<string, unknown>;
    const chatId = meta.chatId as string | undefined;
    const channelId = meta.channelId as string | undefined;
    if (!chatId || !channelId) return;
    try {
      await this.tools.whatsapp.setChatRead({
        channelId,
        chatId,
        read: !unread,
      });
    } catch (error) {
      console.warn(
        `WhatsApp setChatRead failed for chat ${chatId} (read=${!unread})`,
        error
      );
    }
  }

  override async downloadAttachment(ref: string): Promise<
    | { redirectUrl: string }
    | { body: ReadableStream | Uint8Array; mimeType: string; fileName?: string }
  > {
    const colon = ref.indexOf(":");
    if (colon < 0) throw new Error(`Invalid WhatsApp attachment ref: ${ref}`);
    const messageId = ref.slice(0, colon);
    const attachmentId = ref.slice(colon + 1);

    const channelId = await this.get<string>(
      `whatsapp:msg-channel:${messageId}`
    );
    if (!channelId) {
      throw new Error(
        `No WhatsApp channel cached for message ${messageId}. ` +
          `The message may not have been synced through this connector instance.`
      );
    }

    const result = await this.tools.whatsapp.downloadAttachment({
      channelId,
      messageId,
      attachmentId,
    });
    return {
      body: result.body,
      mimeType: result.mimeType,
      fileName: result.fileName,
    };
  }
}

export default WhatsApp;
