import {
  Connector,
  type NewLinkWithNotes,
  type NoteWriteBackResult,
  type ToolBuilder,
} from "@plotday/twister";
import { Options, type OptionsSchema } from "@plotday/twister/options";
import type {
  Actor,
  NewContact,
  NewNote,
  Note,
  Thread,
} from "@plotday/twister/plot";
import { Callbacks } from "@plotday/twister/tools/callbacks";
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
  type LinkedInChat,
  type LinkedInInvitation,
  type LinkedInMessage,
  LinkedInMessaging,
  type LinkedInProfile,
} from "@plotday/unipile";

const TYPE_MESSAGE = "message";
const TYPE_INVITATION = "invitation";
const STATUS_INBOX = "inbox";
const STATUS_ARCHIVE = "archive";
const STATUS_PENDING = "pending";
const PROVIDER_KEY = "linkedin";

const OPTIONS_SCHEMA = {
  importMessages: {
    type: "boolean",
    label: "Sync direct messages",
    default: true,
  },
  importInvitations: {
    type: "boolean",
    label: "Sync connection requests",
    default: true,
  },
} as const satisfies OptionsSchema;

type SyncState = {
  initialSync: boolean;
  lastMessageHighWaterMs: number | null;
  lastInvitationHighWaterMs: number | null;
};

export class LinkedIn extends Connector<LinkedIn> {
  static readonly PROVIDER = AuthProvider.LinkedIn;
  static readonly SCOPES: string[] = [];
  static readonly handleReplies = true;

  readonly provider = AuthProvider.LinkedIn;
  readonly scopes = LinkedIn.SCOPES;
  readonly singleChannel = true;
  readonly linkTypes = [
    {
      type: TYPE_MESSAGE,
      label: "Message",
      logo: "https://api.iconify.design/logos/linkedin-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
      statuses: [
        { status: STATUS_INBOX, label: "Inbox" },
        { status: STATUS_ARCHIVE, label: "Archived" },
      ],
    },
    {
      type: TYPE_INVITATION,
      label: "Connection request",
      logo: "https://api.iconify.design/logos/linkedin-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
      statuses: [
        { status: STATUS_PENDING, label: "Pending" },
        { status: STATUS_ARCHIVE, label: "Archived" },
      ],
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      linkedin: build(LinkedInMessaging),
      network: build(Network, { urls: [] }),
      options: build(Options, OPTIONS_SCHEMA),
      callbacks: build(Callbacks),
      tasks: build(Tasks),
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
    const title = auth?.actor.name ?? "LinkedIn";
    return [{ id: token.token, title }];
  }

  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_state_${channel.id}`, {
      initialSync: true,
      lastMessageHighWaterMs: null,
      lastInvitationHighWaterMs: null,
    } satisfies SyncState);

    const webhookCallback = await this.tools.callbacks.createFromParent(
      this.onWebhookEvent,
      channel.id
    );
    await this.set(`webhook_callback_${channel.id}`, webhookCallback);

    const batch = await this.callback(this.syncBatch, channel.id, true);
    await this.runTask(batch);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`webhook_callback_${channel.id}`);
  }

  async syncBatch(channelId: string, initialSync: boolean): Promise<void> {
    const state = (await this.get<SyncState>(`sync_state_${channelId}`)) ?? {
      initialSync,
      lastMessageHighWaterMs: null,
      lastInvitationHighWaterMs: null,
    };

    const importMessages = this.tools.options.importMessages !== false;
    const importInvitations = this.tools.options.importInvitations !== false;

    let newMessageHigh = state.lastMessageHighWaterMs ?? 0;
    let newInvitationHigh = state.lastInvitationHighWaterMs ?? 0;

    if (importMessages) {
      const since = state.lastMessageHighWaterMs
        ? new Date(state.lastMessageHighWaterMs)
        : undefined;
      const result = await this.tools.linkedin.listChats({
        channelId,
        limit: 20,
        since,
      });
      const links: NewLinkWithNotes[] = [];
      for (const chat of result.chats) {
        const link = await this.buildChatLink(
          channelId,
          chat,
          state.initialSync,
          since
        );
        if (link) links.push(link);
        const t = chat.lastActivityAt.getTime();
        if (t > newMessageHigh) newMessageHigh = t;
      }
      if (links.length > 0) {
        await this.tools.integrations.saveLinks(links);
      }
    }

    if (importInvitations) {
      const result = await this.tools.linkedin.listReceivedInvitations({
        channelId,
        limit: 20,
      });
      const links = result.invitations
        .map((inv) => buildInvitationLink(inv, state.initialSync))
        .filter((l): l is NewLinkWithNotes => l != null);
      for (const inv of result.invitations) {
        const t = inv.sentAt.getTime();
        if (t > newInvitationHigh) newInvitationHigh = t;
      }
      if (links.length > 0) {
        await this.tools.integrations.saveLinks(links);
      }
    }

    await this.set(`sync_state_${channelId}`, {
      initialSync: false,
      lastMessageHighWaterMs: newMessageHigh || null,
      lastInvitationHighWaterMs: newInvitationHigh || null,
    } satisfies SyncState);

    if (state.initialSync) {
      await this.tools.integrations.channelSyncCompleted(channelId);
    }

    const next = await this.callback(this.syncBatch, channelId, false);
    await this.runTask(next, {
      runAt: new Date(Date.now() + 30 * 60 * 1000),
    });
  }

  async onWebhookEvent(
    event:
      | { kind: "message.received"; chatId: string; messageId: string }
      | { kind: "invitation.received"; invitationId: string },
    channelId: string
  ): Promise<void> {
    if (event.kind === "message.received") {
      const chat = await this.tools.linkedin.getChat({
        channelId,
        chatId: event.chatId,
      });
      const link = await this.buildChatLink(channelId, chat, false, undefined);
      if (link) await this.tools.integrations.saveLinks([link]);
    } else {
      const result = await this.tools.linkedin.listReceivedInvitations({
        channelId,
        limit: 1,
      });
      const target = result.invitations.find(
        (i) => i.id === event.invitationId
      );
      if (!target) return;
      const link = buildInvitationLink(target, false);
      if (link) await this.tools.integrations.saveLinks([link]);
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
    const sent = await this.tools.linkedin.sendMessage({
      channelId,
      chatId,
      text: note.content ?? "",
    });
    return {
      key: `message-${sent.id}`,
      externalContent: sent.text,
    };
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
      await this.tools.linkedin.setChatRead({
        channelId,
        chatId,
        read: !unread,
      });
    } catch (error) {
      console.warn(
        `LinkedIn setChatRead failed for chat ${chatId} (read=${!unread})`,
        error
      );
    }
  }

  private async buildChatLink(
    channelId: string,
    chat: LinkedInChat,
    initialSync: boolean,
    since: Date | undefined
  ): Promise<NewLinkWithNotes | null> {
    const messages = await this.tools.linkedin.listMessages({
      channelId,
      chatId: chat.id,
      limit: 20,
      since: initialSync ? undefined : since,
    });

    const notes: NewNote[] = messages.messages
      .slice()
      .reverse()
      .map((msg) => buildNoteFromMessage(msg, chat));

    const contacts = chat.participants
      .map(profileToContact)
      .filter((c): c is NewContact => c != null);

    const title = chat.isGroup
      ? chat.title ?? joinParticipantNames(chat.participants)
      : chat.participants[0]?.fullName ?? "LinkedIn message";

    return {
      source: `linkedin:chat:${chat.id}`,
      sources: [`linkedin:chat:${chat.id}`],
      type: TYPE_MESSAGE,
      status: STATUS_INBOX,
      title,
      preview: chat.lastMessagePreview ?? null,
      sourceUrl: chat.url,
      created: chat.lastActivityAt,
      contacts,
      notes,
      meta: {
        syncProvider: PROVIDER_KEY,
        channelId,
        chatId: chat.id,
        isGroup: chat.isGroup,
      },
      ...(initialSync ? { unread: false, archived: false } : {}),
    } as NewLinkWithNotes;
  }
}

export default LinkedIn;

function buildNoteFromMessage(
  msg: LinkedInMessage,
  chat: LinkedInChat
): NewNote {
  const author = msg.sentByMe
    ? null
    : chat.participants.find((p) => p.id === msg.senderId) ?? null;

  const attachmentSuffix = msg.attachments.length
    ? "\n\n" +
      msg.attachments
        .map(
          (a) =>
            `📎 [${a.name ?? "attachment"}](${a.url})` +
            (a.contentType ? ` (${a.contentType})` : "")
        )
        .join("\n")
    : "";

  return {
    thread: { source: `linkedin:chat:${chat.id}` },
    key: `message-${msg.id}`,
    created: msg.sentAt,
    content: msg.text + attachmentSuffix,
    contentType: "text",
    author: author ? profileToContact(author) ?? undefined : undefined,
  };
}

function profileToContact(profile: LinkedInProfile | null): NewContact | null {
  if (!profile) return null;
  if (profile.email) {
    return {
      email: profile.email,
      name: profile.fullName,
      avatar: profile.pictureUrl ?? undefined,
    };
  }
  if (profile.publicIdentifier) {
    return {
      email: `${profile.publicIdentifier}@linkedin.invalid`,
      name: profile.fullName,
      avatar: profile.pictureUrl ?? undefined,
    };
  }
  return null;
}

function joinParticipantNames(profiles: LinkedInProfile[]): string {
  if (profiles.length === 0) return "LinkedIn group";
  if (profiles.length === 1) return profiles[0]!.fullName;
  if (profiles.length === 2)
    return `${profiles[0]!.fullName}, ${profiles[1]!.fullName}`;
  return `${profiles[0]!.fullName}, ${profiles[1]!.fullName} +${
    profiles.length - 2
  }`;
}

function buildInvitationLink(
  inv: LinkedInInvitation,
  initialSync: boolean
): NewLinkWithNotes | null {
  const contact = profileToContact(inv.inviter);
  if (!contact) return null;

  const notes: NewNote[] = [];
  if (inv.message) {
    notes.push({
      thread: { source: `linkedin:invitation:${inv.id}` },
      key: `invitation-${inv.id}`,
      content: inv.message,
      contentType: "text",
      created: inv.sentAt,
      author: contact,
    });
  }

  return {
    source: `linkedin:invitation:${inv.id}`,
    sources: [
      `linkedin:invitation:${inv.id}`,
      `linkedin:person:${inv.inviter.id}`,
    ],
    type: TYPE_INVITATION,
    status: STATUS_PENDING,
    title: `Connection request from ${inv.inviter.fullName}`,
    preview: inv.message ?? inv.inviter.headline ?? null,
    sourceUrl: inv.inviter.url,
    created: inv.sentAt,
    contacts: [contact],
    notes,
    meta: {
      syncProvider: PROVIDER_KEY,
      channelId: PROVIDER_KEY,
      invitationId: inv.id,
      sharedSecret: inv.sharedSecret,
      inviterId: inv.inviter.id,
    },
    ...(initialSync ? { unread: false, archived: false } : {}),
  } as NewLinkWithNotes;
}
