import {
  Connector,
  type CreateLinkDraft,
  type Link,
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
const TYPE_DM = "linkedin-dm"; // Plot-composed outbound DMs

const STATUS_PENDING  = "pending";
const STATUS_INBOX    = "inbox";
const STATUS_ARCHIVED = "archived";
const STATUS_IGNORED  = "ignored";
const STATUS_SENT     = "sent";

const PROVIDER_KEY = "linkedin";

type SyncState = {
  initialSync: boolean;
  lastMessageHighWaterMs: number | null;
  lastInvitationHighWaterMs: number | null;
};

type RelationsSyncState = {
  cursor: string | null;
  completed: boolean;
  lastCompletedAt: number | null;
  lastPageAt: number;
};

const RELATIONS_PAGE_LIMIT = 100;
const RELATIONS_PAGE_MIN_DELAY_MS = 2 * 60 * 60 * 1000;
const RELATIONS_PAGE_MAX_DELAY_MS = 4 * 60 * 60 * 1000;
const RELATIONS_PAGE_ERROR_MIN_DELAY_MS = 4 * 60 * 60 * 1000;
const RELATIONS_PAGE_ERROR_MAX_DELAY_MS = 8 * 60 * 60 * 1000;
const RELATIONS_REFRESH_MIN_DELAY_MS = 18 * 60 * 60 * 1000;
const RELATIONS_REFRESH_MAX_DELAY_MS = 30 * 60 * 60 * 1000;

// Private connector — references the `"linkedin"` auth provider value
// directly via a typecast since the OSS twister removed
// `AuthProvider.LinkedIn` along with the OSS LinkedIn-messaging connector.
// The runtime stored value is still the string `"linkedin"`.
const LINKEDIN_PROVIDER = "linkedin" as AuthProvider;

export class LinkedIn extends Connector<LinkedIn> {
  static readonly PROVIDER = LINKEDIN_PROVIDER;
  static readonly SCOPES: string[] = [];
  static readonly handleReplies = true;

  readonly provider = LINKEDIN_PROVIDER;
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
    {
      // Compose a new LinkedIn DM from Plot. Opts in to Plot-initiated
      // creation via createDefault: true on the "sent" status.
      type: TYPE_DM,
      label: "New message",
      logo: "https://api.iconify.design/logos/linkedin-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
      targets: "contacts" as const,
      statuses: [
        { status: STATUS_SENT, label: "Sent", createDefault: true },
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

    // Relations backfill — populates Plot contacts so compose can offer
    // every LinkedIn 1st-degree connection as a recipient. First page runs
    // immediately; subsequent pages jittered 2–4h apart. See
    // syncRelationsPage for the rationale.
    await this.set(`relations_state_${channel.id}`, {
      cursor: null,
      completed: false,
      lastCompletedAt: null,
      lastPageAt: 0,
    } satisfies RelationsSyncState);
    const firstRelationsPage = await this.callback(
      this.syncRelationsPage,
      channel.id
    );
    await this.runTask(firstRelationsPage);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`webhook_callback_${channel.id}`);
    await this.clear(`relations_state_${channel.id}`);
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

  /**
   * Conservative paginated backfill of the connected LinkedIn account's
   * 1st-degree relations into Plot's contact table. Each call fetches one
   * page (~100 relations), saves them as contacts, and reschedules itself
   * with a 2–4h jittered delay. Stops rescheduling once Unipile returns
   * `nextCursor === null`. The refresh task (refreshRelationsList) rearms
   * this loop ~once per day to pick up new connections.
   *
   * Pacing is deliberate. Unipile's docs explicitly warn against
   * fixed-interval polling of the relations list; the 2–4h randomized
   * window matches their "first page only a few times a day at random
   * intervals" guidance and keeps the connector well under the documented
   * ~100/day profile-retrieval ceiling (this endpoint is the list, not
   * a per-relation profile fetch).
   */
  async syncRelationsPage(channelId: string): Promise<void> {
    // Channel was disabled mid-loop: bail without rescheduling.
    const webhookCallback = await this.get<string>(
      `webhook_callback_${channelId}`
    );
    if (!webhookCallback) return;

    const state = (await this.get<RelationsSyncState>(
      `relations_state_${channelId}`
    )) ?? {
      cursor: null,
      completed: false,
      lastCompletedAt: null,
      lastPageAt: 0,
    };

    if (state.completed) {
      // Refresh task is what un-completes us. Don't reschedule.
      return;
    }

    let nextCursor: string | null;
    try {
      const page = await this.tools.linkedin.listRelations({
        channelId,
        cursor: state.cursor,
        limit: RELATIONS_PAGE_LIMIT,
      });

      const contacts: NewContact[] = page.relations
        .map(profileToContact)
        .filter((c): c is NewContact => c != null);

      if (contacts.length > 0) {
        await this.tools.integrations.saveContacts(contacts);
      }

      nextCursor = page.nextCursor;

      const completed = nextCursor === null;
      await this.set(`relations_state_${channelId}`, {
        cursor: nextCursor,
        completed,
        lastCompletedAt: completed ? Date.now() : state.lastCompletedAt,
        lastPageAt: Date.now(),
      } satisfies RelationsSyncState);

      if (completed) {
        const refreshDelay =
          RELATIONS_REFRESH_MIN_DELAY_MS +
          Math.random() *
            (RELATIONS_REFRESH_MAX_DELAY_MS - RELATIONS_REFRESH_MIN_DELAY_MS);
        const refresh = await this.callback(
          this.refreshRelationsList,
          channelId
        );
        await this.runTask(refresh, {
          runAt: new Date(Date.now() + refreshDelay),
        });
        return;
      }
    } catch (error) {
      console.warn(
        `LinkedIn relations backfill page failed for channel ${channelId}`,
        error
      );
      // Cursor stays put. Retry on a longer backoff so we don't immediately
      // re-enter a rate-limited window. If scheduling the retry itself fails
      // (transient runtime/DO issue), rethrow so the twist runtime's task-
      // retry machinery handles it — otherwise the backfill loop would be
      // silently dead until the next onChannelEnabled.
      try {
        const errorDelay =
          RELATIONS_PAGE_ERROR_MIN_DELAY_MS +
          Math.random() *
            (RELATIONS_PAGE_ERROR_MAX_DELAY_MS -
              RELATIONS_PAGE_ERROR_MIN_DELAY_MS);
        const retry = await this.callback(this.syncRelationsPage, channelId);
        await this.runTask(retry, {
          runAt: new Date(Date.now() + errorDelay),
        });
      } catch (scheduleError) {
        console.error(
          `LinkedIn relations: failed to schedule retry for channel ${channelId}`,
          scheduleError
        );
        throw error;
      }
      return;
    }

    const delayMs =
      RELATIONS_PAGE_MIN_DELAY_MS +
      Math.random() *
        (RELATIONS_PAGE_MAX_DELAY_MS - RELATIONS_PAGE_MIN_DELAY_MS);
    const next = await this.callback(this.syncRelationsPage, channelId);
    await this.runTask(next, { runAt: new Date(Date.now() + delayMs) });
  }

  /**
   * Rearm the relations backfill loop after a completed pass. Resets the
   * cursor to null and immediately schedules `syncRelationsPage`. Catches
   * relations added/removed since the last full pass without needing a
   * fixed-cadence polling loop.
   */
  async refreshRelationsList(channelId: string): Promise<void> {
    // Channel was disabled mid-loop: bail without rescheduling.
    const webhookCallback = await this.get<string>(
      `webhook_callback_${channelId}`
    );
    if (!webhookCallback) return;

    const state = await this.get<RelationsSyncState>(
      `relations_state_${channelId}`
    );
    await this.set(`relations_state_${channelId}`, {
      cursor: null,
      completed: false,
      lastCompletedAt: state?.lastCompletedAt ?? null,
      lastPageAt: state?.lastPageAt ?? 0,
    } satisfies RelationsSyncState);

    const next = await this.callback(this.syncRelationsPage, channelId);
    await this.runTask(next, { runAt: new Date() });
  }

  async onWebhookEvent(
    event:
      | { kind: "message.received"; chatId: string; messageId: string }
      | { kind: "invitation.received"; invitationId: string }
      | { kind: "relation.new"; profileId: string },
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
    } else if (event.kind === "invitation.received") {
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
    } else {
      // relation.new — a new 1st-degree LinkedIn connection. Fetch the
      // profile and save as a Plot contact. Existing person-keyed links
      // (chats/invitations) will dedupe onto the same contact_external_account
      // row via (LinkedIn, profileId).
      try {
        const profile = await this.tools.linkedin.getProfile({
          channelId,
          profileId: event.profileId,
        });
        const contact = profileToContact(profile);
        await this.tools.integrations.saveContacts([contact]);
      } catch (error) {
        console.warn(
          `LinkedIn new_relation handler failed for profile ${event.profileId}`,
          error
        );
      }
    }
  }

  override async onCreateLink(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    if (draft.type !== TYPE_DM) return null;

    // Resolve recipient ids (LinkedIn provider_id / URN) from the
    // pre-resolved recipients list. For `targets: "contacts"` link types
    // the runtime populates `draft.recipients` with `externalAccountId`
    // values from `contact_external_account` rows keyed on AuthProvider.LinkedIn.
    const recipients = draft.recipients;
    if (!recipients || recipients.length === 0) {
      console.error(
        "[linkedin] onCreateLink: no recipients resolved. LinkedIn DMs require " +
          "a recipient provider id; cannot fall back to email. Ensure contacts " +
          "were synced via the relations backfill or message-ingest profileToContact."
      );
      return null;
    }

    const recipientIds = recipients.map((r) => r.externalAccountId);

    // LinkedIn DMs have no subject line — only a body.
    const body = (draft.noteContent ?? draft.title ?? "").trim();
    if (!body) {
      console.error(
        "[linkedin] onCreateLink: message body is empty; cannot send."
      );
      return null;
    }

    const channelId = draft.channelId;
    const { chatId, message } = await this.tools.linkedin.startChat({
      channelId,
      recipientIds,
      text: body,
    });

    // The returned link must have meta.chatId so that subsequent replies
    // via onNoteCreated can find the conversation without a lookup.
    return {
      source: `linkedin:chat:${chatId}`,
      sources: [`linkedin:chat:${chatId}`],
      type: TYPE_DM,
      status: STATUS_SENT,
      title: draft.title,
      created: message.sentAt,
      channelId,
      meta: {
        syncProvider: PROVIDER_KEY,
        channelId,
        chatId,
        isGroup: recipientIds.length > 1,
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

  override async onLinkUpdated(link: Link): Promise<void> {
    if (link.type !== TYPE_CONVERSATION) return;

    const meta = (link.meta ?? {}) as Record<string, unknown>;
    const channelId    = meta.channelId    as string | undefined;
    const invitationId = meta.invitationId as string | undefined;
    const sharedSecret = meta.sharedSecret as string | undefined;
    if (!channelId) return;
    if (!invitationId || !sharedSecret) return; // chat-only link — nothing to write back

    // Idempotency: each invitation can only be accepted/ignored once.
    // Plot may re-fire onLinkUpdated on unrelated edits (notes, title, etc.).
    const flagKey = `invitation_writeback:${invitationId}`;
    if (await this.get<string>(flagKey)) return;

    // Map Plot status to LinkedIn action. Archived from Pending is treated
    // as Ignore on LinkedIn (user wants this off their plate); the local
    // status stays Archived to match what they clicked.
    let action: "accept" | "ignore" | null = null;
    if (link.status === STATUS_INBOX) action = "accept";
    else if (link.status === STATUS_IGNORED) action = "ignore";
    else if (link.status === STATUS_ARCHIVED) action = "ignore";
    if (!action) return;

    try {
      if (action === "accept") {
        await this.tools.linkedin.acceptInvitation({
          channelId,
          invitationId,
          sharedSecret,
        });
      } else {
        await this.tools.linkedin.ignoreInvitation({
          channelId,
          invitationId,
          sharedSecret,
        });
      }
      await this.set(flagKey, action);
    } catch (error) {
      // Invitation may have been resolved out-of-band; record the attempt so
      // we don't retry a stale invitation on every subsequent edit.
      console.warn(
        `LinkedIn invitation write-back failed (${invitationId}, ${action})`,
        error
      );
      await this.set(flagKey, action);
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

    const contacts = others.map(profileToContact);

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
  const source = { accountId: profile.id };
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
    source: { accountId: msg.senderId },
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
    // status only on initial sync — incremental polls may see a still-pending
    // invitation for a propagation window after the user accepts in Plot;
    // overwriting status would undo their accept.
    ...(initialSync ? { status: STATUS_PENDING } : {}),
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
