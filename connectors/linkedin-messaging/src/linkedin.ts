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
import {
  AuthProvider,
  type Authorization,
  type AuthToken,
  type Channel,
  Integrations,
} from "@plotday/twister/tools/integrations";
import { Callbacks } from "@plotday/twister/tools/callbacks";
import { Tasks } from "@plotday/twister/tools/tasks";
import {
  LinkedIn as LinkedInTool,
  type LinkedInConversation,
  type LinkedInInvitation,
  type LinkedInMessage,
  type LinkedInProfile,
} from "@plotday/twister/tools/linkedin";

const CHANNEL_ID = "linkedin";
const CHANNEL_TITLE = "LinkedIn";

const TYPE_MESSAGE = "message";
const TYPE_INVITATION = "invitation";

const STATUS_INBOX = "inbox";
const STATUS_ARCHIVE = "archive";
const STATUS_PENDING = "pending";

const PROVIDER_KEY = "linkedin";

// Adaptive polling cadences. The connector schedules its next syncBatch at
// one of these intervals based on how recently the user (or LinkedIn) was
// active. Short intervals when activity is fresh; longer when idle.
const CADENCE_FRESH_MIN = 5;
const CADENCE_RECENT_MIN = 15;
const CADENCE_IDLE_MIN = 30;
const FRESH_WINDOW_MS = 60 * 60 * 1000; // 1h
const RECENT_WINDOW_MS = 6 * 60 * 60 * 1000; // 6h

type SyncState = {
  initialSync: boolean;
  // ms timestamp of the most recent activity we've imported. Used to ask
  // LinkedIn for only the conversations updated after this on the next
  // pass.
  lastSyncedActivityAt: number | null;
  // Last time the local user sent a reply through Plot. Used to bias the
  // cadence toward fresh — when the user replied recently they're more
  // likely to be expecting an answer.
  lastUserActivityAt: number | null;
};

/**
 * LinkedIn messaging connector.
 *
 * Reads the user's LinkedIn DM inbox and inbound connection requests via
 * the privileged `LinkedIn` built-in tool. The wire-format details
 * (Voyager endpoints, the cookie/CSRF/User-Agent headers, per-account
 * rate limiting) live entirely server-side; this open-source connector
 * only sees clean, Plot-shaped values.
 *
 * **Authentication.** LinkedIn does not expose an OAuth scope for personal
 * messaging. The Flutter client opens an in-app webview and captures the
 * `li_at` cookie after the user signs in; the API worker validates it via
 * a one-shot Voyager probe and stores it like any other access token.
 * From the connector's perspective this is indistinguishable from OAuth —
 * the `provider` declaration below is `AuthProvider.LinkedIn` and the
 * runtime drives the rest.
 *
 * **Sync model.** No webhooks (LinkedIn doesn't offer them for personal
 * messaging). Instead we poll with an adaptive cadence: 5 min while the
 * user is actively conversing, scaling out to 30 min when idle. Each
 * `syncBatch` lists conversations updated since the last sync and walks
 * their new messages into Plot.
 *
 * **Bidirectional.** Replies in Plot are written back via
 * `tool.sendMessage`; read state is mirrored via `markConversationRead`.
 */
export class LinkedInMessaging extends Connector<LinkedInMessaging> {
  static readonly PROVIDER = AuthProvider.LinkedIn;
  // The cookie carries the full account; LinkedIn doesn't honour OAuth
  // scopes for messaging. We pass an empty list and the runtime treats
  // the connection as "all-or-nothing" the way it does for other
  // cookie-style auth.
  static readonly SCOPES: string[] = [];
  static readonly handleReplies = true;

  readonly provider = AuthProvider.LinkedIn;
  readonly scopes = LinkedInMessaging.SCOPES;
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
      linkedin: build(LinkedInTool),
      callbacks: build(Callbacks),
      tasks: build(Tasks),
    };
  }

  // ---------------------------------------------------------------------------
  // Channel lifecycle
  // ---------------------------------------------------------------------------

  async getChannels(
    _auth: Authorization | null,
    _token: AuthToken | null
  ): Promise<Channel[]> {
    // Single implicit channel — the user's LinkedIn account is the channel.
    // Splitting messages vs. invitations across multiple channels would
    // expose a toggle that nobody actually wants to flip; keep it simple
    // and bundle both into one stream.
    return [{ id: CHANNEL_ID, title: CHANNEL_TITLE }];
  }

  async onChannelEnabled(channel: Channel): Promise<void> {
    // Seed the sync state and queue the first batch as a task. Initial
    // sync runs with the `initialSync` flag so the runtime suppresses
    // notifications during the backfill.
    await this.set(`sync_state_${channel.id}`, {
      initialSync: true,
      lastSyncedActivityAt: null,
      lastUserActivityAt: null,
    } satisfies SyncState);

    const batch = await this.callback(this.syncBatch, channel.id);
    await this.runTask(batch);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    // No webhooks to deregister. Cancel any scheduled future syncs so the
    // task queue doesn't keep firing after the user disabled the channel.
    const scheduledToken = await this.get<string>(
      `next_sync_task_${channel.id}`
    );
    if (scheduledToken) {
      try {
        await this.tools.tasks.cancelTask(scheduledToken);
      } catch {
        // No-op — cancel is idempotent and the token may already have fired.
      }
    }
    await this.clear(`next_sync_task_${channel.id}`);
    await this.clear(`sync_state_${channel.id}`);
  }

  // ---------------------------------------------------------------------------
  // Sync loop
  // ---------------------------------------------------------------------------

  /**
   * One adaptive-poll cycle. Runs in its own execution (queued via
   * `runTask`) so each cycle gets a fresh ~1000-request budget.
   *
   * 1. List conversations updated since `lastSyncedActivityAt`.
   * 2. For each conversation, list its new messages and save the link +
   *    notes.
   * 3. Walk inbound connection invitations as a separate stream.
   * 4. Schedule the next cycle based on activity recency.
   */
  async syncBatch(channelId: string): Promise<void> {
    const state =
      (await this.get<SyncState>(`sync_state_${channelId}`)) ?? {
        initialSync: false,
        lastSyncedActivityAt: null,
        lastUserActivityAt: null,
      };

    const since = state.lastSyncedActivityAt
      ? new Date(state.lastSyncedActivityAt)
      : undefined;

    let cursor: string | null = null;
    let highWaterMark = state.lastSyncedActivityAt ?? 0;
    const conversationLinks: NewLinkWithNotes[] = [];

    // Conversations
    for (let page = 0; page < 5; page++) {
      const result = await this.tools.linkedin.listConversations({
        channelId,
        cursor,
        since,
        limit: 20,
      });
      for (const conv of result.conversations) {
        const link = await this.buildConversationLink(
          channelId,
          conv,
          state.initialSync,
          since
        );
        if (link) conversationLinks.push(link);
        const ts = conv.lastActivityAt.getTime();
        if (ts > highWaterMark) highWaterMark = ts;
      }
      if (!result.nextCursor || result.conversations.length === 0) break;
      cursor = result.nextCursor;
    }

    if (conversationLinks.length > 0) {
      await this.tools.integrations.saveLinks(conversationLinks);
    }

    // Invitations (one page per cycle is plenty — most users see a few per
    // day at most).
    if (state.initialSync || sinceWasRecent(since)) {
      const invitations = await this.tools.linkedin.listConnectionInvitations({
        channelId,
        limit: 20,
      });
      const invitationLinks = invitations.invitations
        .map((inv) => buildInvitationLink(channelId, inv, state.initialSync))
        .filter((link): link is NewLinkWithNotes => link != null);
      if (invitationLinks.length > 0) {
        await this.tools.integrations.saveLinks(invitationLinks);
      }
    }

    // Persist progress.
    await this.set(`sync_state_${channelId}`, {
      initialSync: false,
      lastSyncedActivityAt: highWaterMark || Date.now(),
      lastUserActivityAt: state.lastUserActivityAt,
    } satisfies SyncState);

    // Tell the runtime we're done backfilling so the "syncing…" indicator
    // clears on first pass.
    if (state.initialSync) {
      await this.tools.integrations.channelSyncCompleted(channelId);
    }

    // Schedule the next cycle.
    await this.scheduleNextSync(channelId, {
      lastUserActivityAt: state.lastUserActivityAt,
      lastSyncedActivityAt: highWaterMark,
    });
  }

  private async scheduleNextSync(
    channelId: string,
    activity: { lastUserActivityAt: number | null; lastSyncedActivityAt: number }
  ): Promise<void> {
    const now = Date.now();
    const sinceUserMs = activity.lastUserActivityAt
      ? now - activity.lastUserActivityAt
      : Infinity;
    const sinceActivityMs = activity.lastSyncedActivityAt
      ? now - activity.lastSyncedActivityAt
      : Infinity;
    const sinceAnyMs = Math.min(sinceUserMs, sinceActivityMs);

    let cadenceMin: number;
    if (sinceAnyMs < FRESH_WINDOW_MS) cadenceMin = CADENCE_FRESH_MIN;
    else if (sinceAnyMs < RECENT_WINDOW_MS) cadenceMin = CADENCE_RECENT_MIN;
    else cadenceMin = CADENCE_IDLE_MIN;

    const runAt = new Date(now + cadenceMin * 60 * 1000);
    const callback = await this.callback(this.syncBatch, channelId);
    const taskToken = await this.runTask(callback, { runAt });
    if (taskToken) {
      await this.set(`next_sync_task_${channelId}`, taskToken);
    }
  }

  // ---------------------------------------------------------------------------
  // Voyager → Plot mapping
  // ---------------------------------------------------------------------------

  private async buildConversationLink(
    channelId: string,
    conv: LinkedInConversation,
    initialSync: boolean,
    since: Date | undefined
  ): Promise<NewLinkWithNotes | null> {
    // Pull the new messages for this conversation. On initial sync we
    // walk a single page (~20 messages) so the backfill stays bounded.
    const messagesResult = await this.tools.linkedin.getMessages({
      channelId,
      conversationUrn: conv.urn,
      since: initialSync ? undefined : since,
      limit: 20,
    });

    const notes: NewNote[] = messagesResult.messages
      .slice()
      .reverse() // Voyager returns newest first; Plot wants oldest first.
      .map((msg) => buildNoteFromMessage(msg, conv));

    const contacts: NewContact[] = conv.participants
      .map(profileToContact)
      .filter((c): c is NewContact => c != null);

    const title = conv.isGroup
      ? conv.title ?? joinParticipantNames(conv.participants)
      : conv.participants[0]?.fullName ?? "LinkedIn message";

    return {
      source: `linkedin:conversation:${conv.urn}`,
      sources: [`linkedin:conversation:${conv.urn}`],
      type: TYPE_MESSAGE,
      status: STATUS_INBOX,
      title,
      preview: conv.lastMessagePreview ?? null,
      sourceUrl: conv.url,
      created: conv.lastActivityAt,
      contacts,
      notes,
      meta: {
        syncProvider: PROVIDER_KEY,
        channelId,
        conversationUrn: conv.urn,
        isGroup: conv.isGroup,
      },
      ...(initialSync ? { unread: false, archived: false } : {}),
    } as NewLinkWithNotes;
  }

  // ---------------------------------------------------------------------------
  // Write-back
  // ---------------------------------------------------------------------------

  override async onNoteCreated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    const meta = thread.meta ?? {};
    const conversationUrn = meta.conversationUrn as string | undefined;
    const channelId =
      (meta.channelId as string | undefined) ?? CHANNEL_ID;
    if (!conversationUrn) return;

    const sent = await this.tools.linkedin.sendMessage({
      channelId,
      conversationUrn,
      text: note.content ?? "",
    });

    // Bias the next poll cycle to be fresh — the user just replied so a
    // response is likely incoming soon.
    const state =
      (await this.get<SyncState>(`sync_state_${channelId}`)) ?? null;
    if (state) {
      await this.set(`sync_state_${channelId}`, {
        ...state,
        lastUserActivityAt: Date.now(),
      } satisfies SyncState);
    }

    return {
      key: `message-${sent.urn}`,
      externalContent: sent.text,
    };
  }

  override async onThreadRead(
    thread: Thread,
    _actor: Actor,
    unread: boolean
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const conversationUrn = meta.conversationUrn as string | undefined;
    const channelId =
      (meta.channelId as string | undefined) ?? CHANNEL_ID;
    if (!conversationUrn) return;

    try {
      await this.tools.linkedin.markConversationRead({
        channelId,
        conversationUrn,
        read: !unread,
      });
    } catch (error) {
      // Read-state sync is best-effort — log and swallow so a transient
      // LinkedIn error doesn't bubble up to the user.
      console.warn(
        `LinkedIn: failed to mark conversation ${conversationUrn} read=${!unread}`,
        error
      );
    }
  }
}

export default LinkedInMessaging;

// ---------------------------------------------------------------------------
// Pure helpers (no `this` references — keeps the class focused)
// ---------------------------------------------------------------------------

function buildNoteFromMessage(
  msg: LinkedInMessage,
  conv: LinkedInConversation
): NewNote {
  const author = senderProfile(msg.senderUrn, conv);
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

  const note: NewNote = {
    thread: { source: `linkedin:conversation:${conv.urn}` },
    key: `message-${msg.urn}`,
    created: msg.sentAt,
    author: author ? profileToContact(author) ?? undefined : undefined,
  };

  if (msg.html) {
    note.content = msg.html + attachmentSuffix.replace(/\n/g, "<br>");
    note.contentType = "html";
  } else {
    note.content = msg.text + attachmentSuffix;
    note.contentType = "text";
  }

  return note;
}

function senderProfile(
  senderUrn: string,
  conv: LinkedInConversation
): LinkedInProfile | null {
  return (
    conv.participants.find((p) => p.urn === senderUrn) ??
    (conv.participants.length === 1 ? conv.participants[0] ?? null : null)
  );
}

function profileToContact(profile: LinkedInProfile | null): NewContact | null {
  if (!profile) return null;
  // Anchor the contact on email when available, otherwise on the LinkedIn
  // public identifier (slug). Profiles without either are surfaced as a
  // bare display contact — they're rare in practice (only when the user
  // talks to someone whose profile is heavily restricted).
  if (profile.email) {
    return {
      email: profile.email,
      name: profile.fullName,
      avatar: profile.pictureUrl ?? undefined,
    };
  }
  // No email: synthesize a deterministic, scoped pseudo-email so the
  // contact dedupes correctly across messages from the same person. This
  // is consistent with how Slack handles workspaces where email is
  // hidden.
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
  return `${profiles[0]!.fullName}, ${profiles[1]!.fullName} +${profiles.length - 2}`;
}

function buildInvitationLink(
  channelId: string,
  inv: LinkedInInvitation,
  initialSync: boolean
): NewLinkWithNotes | null {
  const contact = profileToContact(inv.inviter);
  if (!contact) return null;

  const notes: NewNote[] = [];
  if (inv.message) {
    notes.push({
      thread: { source: `linkedin:invitation:${inv.urn}` },
      key: `invitation-${inv.urn}`,
      content: inv.message,
      contentType: "text",
      created: inv.sentAt,
      author: contact,
    });
  }

  return {
    source: `linkedin:invitation:${inv.urn}`,
    // Carry both the invitation id and the inviter's profile URN so a
    // future message from the same person can converge onto the same
    // thread via sources[] overlap.
    sources: [
      `linkedin:invitation:${inv.urn}`,
      `linkedin:person:${inv.inviter.urn}`,
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
      channelId,
      invitationUrn: inv.urn,
      sharedSecret: inv.sharedSecret,
      inviterUrn: inv.inviter.urn,
    },
    ...(initialSync ? { unread: false, archived: false } : {}),
  } as NewLinkWithNotes;
}

function sinceWasRecent(since: Date | undefined): boolean {
  if (!since) return true;
  return Date.now() - since.getTime() < RECENT_WINDOW_MS;
}
