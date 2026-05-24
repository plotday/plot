import {
  Connector,
  type NewLinkWithNotes,
  type NoteWriteBackResult,
  type ToolBuilder,
} from "@plotday/twister";
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

const TYPE_CONVERSATION = "conversation"; // 1:1 chats + invitations
const TYPE_GROUP = "group";

const STATUS_PENDING  = "pending";
const STATUS_INBOX    = "inbox";
const STATUS_ARCHIVED = "archived";
const STATUS_IGNORED  = "ignored";

const PROVIDER_KEY = "linkedin";

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
      type: TYPE_CONVERSATION,
      label: "LinkedIn conversation",
      logo: "https://api.iconify.design/logos/linkedin-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
      statuses: [
        { status: STATUS_PENDING,  label: "Pending" },
        { status: STATUS_INBOX,    label: "Connected" },
        { status: STATUS_ARCHIVED, label: "Archived", done: true },
        { status: STATUS_IGNORED,  label: "Ignored",  done: true },
      ],
    },
    {
      type: TYPE_GROUP,
      label: "LinkedIn group",
      logo: "https://api.iconify.design/logos/linkedin-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
      statuses: [
        { status: STATUS_INBOX,    label: "Inbox" },
        { status: STATUS_ARCHIVED, label: "Archived", done: true },
      ],
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      linkedin: build(LinkedInMessaging),
      network: build(Network, { urls: [] }),
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

    let newMessageHigh = state.lastMessageHighWaterMs ?? 0;
    let newInvitationHigh = state.lastInvitationHighWaterMs ?? 0;

    // Invitations first so a follow-up chat sync converges onto the same
    // person-keyed link (and flips status from Pending → Connected if the
    // user has already accepted on LinkedIn between syncs).
    {
      const result = await this.tools.linkedin.listReceivedInvitations({
        channelId,
        limit: 20,
      });
      const links = result.invitations.map((inv) =>
        buildInvitationLink(channelId, inv, state.initialSync)
      );
      for (const inv of result.invitations) {
        const t = inv.sentAt.getTime();
        if (t > newInvitationHigh) newInvitationHigh = t;
      }
      if (links.length > 0) {
        await this.tools.integrations.saveLinks(links);
      }
    }

    {
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
        const link = chat.isGroup
          ? await this.buildGroupLink(channelId, chat, state.initialSync, since)
          : await this.build1to1ConversationLink(
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
      const link = chat.isGroup
        ? await this.buildGroupLink(channelId, chat, false, undefined)
        : await this.build1to1ConversationLink(channelId, chat, false, undefined);
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
      const link = buildInvitationLink(channelId, target, false);
      await this.tools.integrations.saveLinks([link]);
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

  private async build1to1ConversationLink(
    channelId: string,
    chat: LinkedInChat,
    initialSync: boolean,
    since: Date | undefined
  ): Promise<NewLinkWithNotes | null> {
    const other = chat.participants.find((p) => !p.isSelf);
    if (!other) return null; // no counterparty — skip

    const messages = await this.tools.linkedin.listMessages({
      channelId,
      chatId: chat.id,
      limit: 20,
      since: initialSync ? undefined : since,
    });
    const notes: NewNote[] = messages.messages
      .slice()
      .reverse()
      .map((msg) => buildNoteFromMessage(msg, chat, other.id));

    const contact = profileToContact(other);

    return {
      source: `linkedin:person:${other.id}`,
      sources: [
        `linkedin:person:${other.id}`,
        `linkedin:chat:${chat.id}`,
      ],
      type: TYPE_CONVERSATION,
      // status is only written on initial sync — incremental syncs must not
      // re-promote a user-set Archived/Ignored back to Inbox on every poll.
      ...(initialSync ? { status: STATUS_INBOX } : {}),
      title: other.fullName,
      preview: chat.lastMessagePreview ?? null,
      sourceUrl: chat.url,
      created: chat.lastActivityAt,
      accessContacts: [contact],
      notes,
      meta: {
        syncProvider: PROVIDER_KEY,
        channelId,
        profileId: other.id,
        chatId: chat.id,
      },
      ...(initialSync ? { unread: false, archived: false } : {}),
    } satisfies NewLinkWithNotes;
  }

  private async buildGroupLink(
    channelId: string,
    chat: LinkedInChat,
    initialSync: boolean,
    since: Date | undefined
  ): Promise<NewLinkWithNotes> {
    const messages = await this.tools.linkedin.listMessages({
      channelId,
      chatId: chat.id,
      limit: 20,
      since: initialSync ? undefined : since,
    });

    const others = chat.participants.filter((p) => !p.isSelf);
    const notes: NewNote[] = messages.messages
      .slice()
      .reverse()
      .map((msg) => buildNoteFromMessage(msg, chat));

    const contacts = others
      .map(profileToContact)
      .filter((c): c is NewContact => c != null);

    const title = chat.title ?? joinParticipantNames(others);

    return {
      source: `linkedin:chat:${chat.id}`,
      sources: [`linkedin:chat:${chat.id}`],
      type: TYPE_GROUP,
      // status is only written on initial sync — incremental syncs must not
      // re-promote a user-set Archived/Ignored back to Inbox on every poll.
      ...(initialSync ? { status: STATUS_INBOX } : {}),
      title,
      preview: chat.lastMessagePreview ?? null,
      sourceUrl: chat.url,
      created: chat.lastActivityAt,
      accessContacts: contacts,
      notes,
      meta: {
        syncProvider: PROVIDER_KEY,
        channelId,
        chatId: chat.id,
      },
      ...(initialSync ? { unread: false, archived: false } : {}),
    } satisfies NewLinkWithNotes;
  }
}

export default LinkedIn;

function buildNoteFromMessage(
  msg: LinkedInMessage,
  chat: LinkedInChat,
  threadPersonId?: string,
): NewNote {
  const sender = chat.participants.find((p) => p.id === msg.senderId) ?? null;
  const author = sender
    ? profileToContact(sender)
    : senderFallbackContact(msg);

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

  const threadSource = threadPersonId
    ? `linkedin:person:${threadPersonId}`
    : `linkedin:chat:${chat.id}`;

  return {
    thread: { source: threadSource },
    key: `message-${msg.id}`,
    created: msg.sentAt,
    content: msg.text + attachmentSuffix,
    contentType: "text",
    author,
  };
}

function profileToContact(profile: LinkedInProfile): NewContact {
  const source = {
    provider: AuthProvider.LinkedIn,
    accountId: profile.id,
  };
  const avatar = profile.pictureUrl ?? undefined;
  if (profile.email) {
    return { email: profile.email, name: profile.fullName, avatar, source };
  }
  if (profile.publicIdentifier) {
    return {
      email: `${profile.publicIdentifier}@linkedin.invalid`,
      name: profile.fullName,
      avatar,
      source,
    };
  }
  return { name: profile.fullName, avatar, source };
}

function senderFallbackContact(msg: LinkedInMessage): NewContact {
  return {
    name: msg.sentByMe ? "You" : "LinkedIn user",
    source: { provider: AuthProvider.LinkedIn, accountId: msg.senderId },
  };
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
  channelId: string,
  inv: LinkedInInvitation,
  initialSync: boolean
): NewLinkWithNotes {
  const contact = profileToContact(inv.inviter);

  const notes: NewNote[] = [];
  if (inv.message) {
    notes.push({
      thread: { source: `linkedin:person:${inv.inviter.id}` },
      key: `invitation-${inv.id}`,
      content: inv.message,
      contentType: "text",
      created: inv.sentAt,
      author: contact,
    });
  }

  return {
    source: `linkedin:person:${inv.inviter.id}`,
    sources: [
      `linkedin:person:${inv.inviter.id}`,
      `linkedin:invitation:${inv.id}`,
    ],
    type: TYPE_CONVERSATION,
    status: STATUS_PENDING,
    title: inv.inviter.fullName,
    preview: inv.message ?? inv.inviter.headline ?? null,
    sourceUrl: inv.inviter.url,
    created: inv.sentAt,
    accessContacts: [contact],
    notes,
    meta: {
      syncProvider: PROVIDER_KEY,
      channelId,
      profileId: inv.inviter.id,
      invitationId: inv.id,
      sharedSecret: inv.sharedSecret,
    },
    ...(initialSync ? { unread: false, archived: false } : {}),
  } satisfies NewLinkWithNotes;
}
