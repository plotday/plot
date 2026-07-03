import {
  Connector,
  type CreateLinkDraft,
  type Link,
  type NewLinkWithNotes,
  type NoteWriteBackResult,
  type ReactionCapabilities,
  type ToolBuilder,
} from "@plotday/twister";
import { markdownToPlainText } from "@plotday/twister/utils/markdown";
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
  type StatusIcon,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";
import {
  buildLinkForChat,
  type ChatThread,
  InstagramMessaging,
  reconcilePerUserReaction,
} from "@plotday/unipile";

const TYPE_CONVERSATION = "conversation";
const TYPE_GROUP = "group";
// Only two statuses model real Instagram message-request state: `pending`
// (an inbound message request awaiting the user's decision, shown as
// "Request") and `inbox` (the resting accepted state). Moving a pending
// link to Inbox accepts the request from inside Plot (see `onLinkUpdated`).
// Archival/ignore statuses were removed — archiving a thread is a Plot
// concept and no longer writes back to Instagram.
const STATUS_PENDING = "pending";
const STATUS_INBOX = "inbox";
const PROVIDER_KEY = "instagram";

// Private connector — references the `"instagram"` auth provider value directly
// via a typecast since the OSS twister does not enumerate it in AuthProvider.
// The runtime stored value is still the string `"instagram"`.
const INSTAGRAM_PROVIDER = "instagram" as AuthProvider;

/**
 * A 1:1 Instagram chat is a *message request* (inbound DM from someone the
 * connected account doesn't follow) until accepted. Unipile surfaces these via
 * a non-inbox folder. Group chats are never requests.
 */
function isRequest(chat: ChatThread): boolean {
  // LIVE-CONFIRM: exact v2 folder value for IG message requests.
  return (chat.folder ?? "").toUpperCase().includes("REQUEST");
}

export class Instagram extends Connector<Instagram> {
  static readonly PROVIDER = INSTAGRAM_PROVIDER;
  static readonly SCOPES: string[] = [];
  static readonly handleReplies = true;

  readonly provider = INSTAGRAM_PROVIDER;
  readonly scopes = Instagram.SCOPES;
  readonly access = [
    "Reads your Instagram direct messages",
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
      label: "Chat",
      sharingModel: "thread" as const,
      logo: "https://api.iconify.design/logos/instagram-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/instagram.svg",
      compose: { targets: "addresses" as const, status: STATUS_INBOX },
      statuses: [
        { status: STATUS_PENDING, label: "Request", icon: "tentative" as StatusIcon },
        // "Inbox" is the resting accepted state — hide its glyph on the feed
        // row so only message requests stand out.
        { status: STATUS_INBOX, label: "Inbox", icon: "confirmed" as StatusIcon, hiddenDefault: true },
      ],
    },
    {
      type: TYPE_GROUP,
      label: "Group",
      sharingModel: "thread" as const,
      logo: "https://api.iconify.design/logos/instagram-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/instagram.svg",
      // Group chats are never message requests, so the only status is the
      // resting accepted state — hidden on the feed row.
      statuses: [
        { status: STATUS_INBOX, label: "Inbox", icon: "confirmed" as StatusIcon, hiddenDefault: true },
      ],
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      instagram: build(InstagramMessaging),
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
    return [{ id: token.token, title: auth?.actor.name ?? "Instagram" }];
  }

  async onChannelEnabled(channel: Channel): Promise<void> {
    // Register the webhook callback first so new messages flow as soon as
    // the account is live.
    const cb = await this.tools.callbacks.createFromParent(
      this.onWebhookEvent,
      channel.id
    );
    await this.set(`webhook_callback_${channel.id}`, cb);

    // One-time backfill of existing chats. No relations crawl — Instagram has
    // no equivalent. No recurring poll — webhooks drive steady state.
    const task = await this.callback(this.backfill, channel.id);
    await this.runTask(task);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.clear(`webhook_callback_${channel.id}`);
  }

  /**
   * One-time backfill of existing Instagram conversations and groups.
   *
   * Re-implements the chat loop (rather than using the shared `backfillChats`)
   * so each 1:1 chat can carry a per-chat status override: message requests
   * land as `pending` instead of `inbox`. Group chats are never requests.
   * `buildLinkForChat` routes group chats to `assembleGroupLink` (which ignores
   * `conversationStatus`) and 1:1 chats to `assembleConversationLink`.
   */
  async backfill(channelId: string): Promise<void> {
    const { chats } = await this.tools.instagram.listChats({
      channelId,
      limit: 20,
    });
    const links: NewLinkWithNotes[] = [];
    for (const chat of chats) {
      const conversationStatus =
        !chat.isGroup && isRequest(chat) ? STATUS_PENDING : STATUS_INBOX;
      const link = await buildLinkForChat({
        tool: this.tools.instagram,
        provider: PROVIDER_KEY,
        channelId,
        chat,
        initialSync: true,
        conversationStatus,
        onAttachmentMessage: (id) =>
          this.set(`instagram:msg-channel:${id}`, channelId),
      });
      if (link) {
        if (conversationStatus === STATUS_PENDING) {
          link.meta = { ...(link.meta ?? {}), isRequest: true };
        }
        links.push(link);
      }
    }
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
    const chat = await this.tools.instagram.getChat({
      channelId,
      chatId: event.chatId,
    });
    // No `conversationStatus` on the incremental path: `assembleConversationLink`
    // only applies a status on initial sync, so a still-pending request stays
    // pending until the user acts, and an accepted chat is not reverted.
    const link = await buildLinkForChat({
      tool: this.tools.instagram,
      provider: PROVIDER_KEY,
      channelId,
      chat,
      initialSync: false,
      onAttachmentMessage: (id) =>
        this.set(`instagram:msg-channel:${id}`, channelId),
    });
    if (link) await this.tools.integrations.saveLinks([link]);
  }

  override async onCreateLink(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    if (draft.type !== TYPE_CONVERSATION) return null;

    const body = (draft.noteContent ?? draft.title ?? "").trim();
    if (!body) {
      console.error("[instagram] onCreateLink: empty body");
      return null;
    }

    // Collect recipient ids from pre-resolved contacts (runtime-resolved
    // contact_external_account rows for "addresses" link types) PLUS any
    // free-form addresses the user typed (inviteEmails). Free-form addresses
    // are resolved via resolveRecipient (@username → IG user id).
    const ids: string[] = [];

    for (const r of draft.recipients ?? []) {
      ids.push(r.externalAccountId);
    }

    for (const addr of draft.inviteEmails ?? []) {
      const resolved = await this.tools.instagram.resolveRecipient({
        channelId: draft.channelId,
        address: addr,
      });
      if (resolved) ids.push(resolved);
    }

    if (ids.length === 0) {
      console.error("[instagram] onCreateLink: no recipients resolved");
      return null;
    }

    const isGroup = ids.length > 1;
    const { chatId, message } = await this.tools.instagram.startChat({
      channelId: draft.channelId,
      recipientIds: ids,
      text: body,
    });

    return {
      source: isGroup
        ? `instagram:chat:${chatId}`
        : `instagram:person:${ids[0]}`,
      sources: isGroup
        ? [`instagram:chat:${chatId}`]
        : [`instagram:person:${ids[0]}`, `instagram:chat:${chatId}`],
      type: TYPE_CONVERSATION,
      status: STATUS_INBOX,
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

  /**
   * Accept an Instagram message request when the user moves a `pending`
   * conversation link to "Inbox" in Plot. Mirrors LinkedIn's idempotent
   * invitation write-back: the only transition is accept. There is no
   * ignore/archive status anymore, so other transitions are no-ops. A
   * `request_writeback:<chatId>` flag guards against re-firing on unrelated
   * edits (notes, title, etc.).
   */
  override async onLinkUpdated(link: Link): Promise<void> {
    if (link.type !== TYPE_CONVERSATION) return;

    const meta = (link.meta ?? {}) as Record<string, unknown>;
    const channelId = meta.channelId as string | undefined;
    const chatId = meta.chatId as string | undefined;
    if (!channelId || !chatId) return;

    // Only write back links that originated as message requests.
    if (meta.isRequest !== true) return;

    // Idempotency: each request is accepted at most once.
    const flagKey = `request_writeback:${chatId}`;
    if (await this.get<string>(flagKey)) return;

    // The only write-back is accept: moving a pending request to "Inbox"
    // accepts it. Other transitions leave the flag unset so a later accept
    // still writes back.
    if (link.status !== STATUS_INBOX) return;

    try {
      await this.tools.instagram.setMessageRequestAccepted({
        channelId,
        chatId,
        accepted: true,
      });
      await this.set(flagKey, "accept");
    } catch (error) {
      // Request may have been resolved out-of-band; record the attempt so we
      // don't retry a stale request on every subsequent edit.
      console.warn(
        `Instagram request write-back failed (${chatId}, accept)`,
        error
      );
      await this.set(flagKey, "accept");
    }
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
        console.error("Instagram attachment read failed", a.fileId, e);
      }
    }

    const sent = await this.tools.instagram.sendMessage({
      channelId,
      chatId,
      // Instagram DMs are plain text — strip Markdown so the recipient sees
      // clean text (e.g. "bold", not "**bold**") instead of literal syntax.
      text: markdownToPlainText(note.content ?? ""),
      attachments: attachments.length > 0 ? attachments : undefined,
    });
    return { key: `message-${sent.id}`, externalContent: sent.text };
  }

  /**
   * Pushes a single emoji add/remove back to Instagram, attributed to the
   * reacting user (dispatched on their own connector instance via
   * `twist_instance_for_actor`). Instagram allows one open-unicode reaction per
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
    const chatId = meta.chatId as string | undefined;
    if (!channelId || !chatId) return;
    if (!note.key || !note.key.startsWith("message-")) return;
    const messageId = note.key.slice("message-".length);
    if (!messageId) return;

    const stateKey = `reaction_sent:${messageId}`;
    const lastSent = (await this.get<string>(stateKey)) ?? null;
    const decision = reconcilePerUserReaction(lastSent, emoji, added);
    if (decision.action === "none") return;

    try {
      if (decision.action === "set") {
        await this.tools.instagram.setMessageReaction({
          channelId,
          chatId,
          messageId,
          reaction: decision.emoji,
        });
        await this.set(stateKey, decision.emoji);
      } else {
        await this.tools.instagram.clearMessageReaction({ channelId, chatId, messageId });
        await this.clear(stateKey);
      }
    } catch (error) {
      console.warn(
        `Instagram reaction write-back failed for message ${messageId}`,
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
      await this.tools.instagram.setChatRead({
        channelId,
        chatId,
        read: !unread,
      });
    } catch (error) {
      console.warn(
        `Instagram setChatRead failed for chat ${chatId} (read=${!unread})`,
        error
      );
    }
  }

  override async downloadAttachment(ref: string): Promise<
    | { redirectUrl: string }
    | { body: ReadableStream | Uint8Array; mimeType: string; fileName?: string }
  > {
    const colon = ref.indexOf(":");
    if (colon < 0) throw new Error(`Invalid Instagram attachment ref: ${ref}`);
    const messageId = ref.slice(0, colon);
    const attachmentId = ref.slice(colon + 1);

    const channelId = await this.get<string>(
      `instagram:msg-channel:${messageId}`
    );
    if (!channelId) {
      throw new Error(
        `No Instagram channel cached for message ${messageId}. ` +
          `The message may not have been synced through this connector instance.`
      );
    }

    const result = await this.tools.instagram.downloadAttachment({
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

export default Instagram;
