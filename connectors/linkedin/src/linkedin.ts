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
import type {
  Action,
  Actor,
  NewContact,
  NewNote,
  Note,
  Thread,
} from "@plotday/twister/plot";
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
  backfillChats,
  buildLinkForChat,
  type LinkedInInvitation,
  LinkedInMessaging,
  profileToContact,
  reconcilePerUserReaction,
} from "@plotday/unipile";

// LinkedIn has a single composable link type: `conversation` covers 1:1 AND
// multi-person chats, and an inbound connection request (invitation) is the
// `pending` status on that same type. There is no named-group entity on
// LinkedIn messaging — a chat is just its participant set — so multi-person
// chats are `conversation` links whose `accessContacts` has >1 entry.
const TYPE_CONVERSATION = "conversation";

// Only two statuses model real LinkedIn invitation state: `pending` (an
// inbound connection request awaiting the user's decision) and `inbox`
// ("Connected", the resting accepted state). Moving a pending link to
// Connected accepts the invitation from inside Plot (see `onLinkUpdated`).
// Authorship/archival statuses were removed — archiving a thread is a Plot
// concept and no longer writes back to LinkedIn.
const STATUS_PENDING = "pending";
const STATUS_INBOX    = "inbox";

const PROVIDER_KEY = "linkedin";

/**
 * LinkedIn DMs accept exactly these seven emoji as message reactions; the
 * platform does not expose a custom-reaction picker. The connector declares
 * this via `reactionCapabilities` so the Plot reaction picker (see
 * `reactionCapabilitiesForLinkSource` in
 * `apps/plot/lib/store/reaction.dart`) filters out anything else before the
 * user can attempt to react.
 *
 * The order doubles as the deterministic tiebreaker when multiple Plot
 * users have reacted with different allowed emoji on the same note —
 * LinkedIn only lets each member set one reaction, so the connector picks
 * the first match in this list as the one to push.
 */
const LINKEDIN_REACTIONS = ["👍", "❤️", "👏", "💡", "😂", "😮", "😢"] as const;

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
  readonly access = [
    "Reads your LinkedIn messages and conversations",
    "Sends messages and replies you write in Plot",
  ];
  readonly singleChannel = true;
  readonly reactionCapabilities: ReactionCapabilities = {
    mode: "fixed",
    allowed: LINKEDIN_REACTIONS,
  };
  readonly linkTypes = [
    {
      type: TYPE_CONVERSATION,
      label: "LinkedIn conversation",
      sharingModel: "thread" as const,
      logo: "https://api.iconify.design/logos/linkedin-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
      // LinkedIn DMs are a closed roster — compose targets existing contacts
      // (1st-degree connections synced via the relations backfill), not
      // free-form addresses.
      compose: { targets: "contacts" as const, status: STATUS_INBOX },
      statuses: [
        { status: STATUS_PENDING, label: "Pending", icon: "tentative" as StatusIcon },
        // "Connected" is the resting accepted state — hide its glyph on the
        // feed row so only pending requests stand out.
        { status: STATUS_INBOX, label: "Connected", icon: "confirmed" as StatusIcon, hiddenDefault: true },
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
    const title = auth?.actor.name ?? "LinkedIn";
    return [{ id: token.token, title }];
  }

  async onChannelEnabled(channel: Channel): Promise<void> {
    // Register the webhook callback first so steady-state new-message,
    // invitation, and relation events flow as soon as the account is live.
    const webhookCallback = await this.tools.callbacks.createFromParent(
      this.onWebhookEvent,
      channel.id
    );
    await this.set(`webhook_callback_${channel.id}`, webhookCallback);

    // One-time backfill of existing chats + pending invitations. No recurring
    // poll — webhooks drive steady state.
    const backfill = await this.callback(this.backfill, channel.id);
    await this.runTask(backfill);

    // Relations backfill — populates Plot contacts so compose can offer
    // every LinkedIn 1st-degree connection as a recipient. First page runs
    // immediately; subsequent pages jittered 2–4h apart. One-time crawl: once
    // Unipile returns nextCursor === null we stop (no refresh loop). New
    // relations arrive via the `relation.new` webhook.
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
    await this.clear(`webhook_callback_${channel.id}`);
    await this.clear(`relations_state_${channel.id}`);
  }

  /**
   * One-time backfill of existing LinkedIn conversations. Invitations are
   * processed first so a follow-up chat sync converges onto the same
   * person-keyed link (and flips status from Pending → Connected if the user
   * already accepted on LinkedIn). Chats then sync via the shared
   * `backfillChats` helper. Multi-person chats become `conversation` links
   * (groupType: "conversation") since LinkedIn has no named-group entity.
   */
  async backfill(channelId: string): Promise<void> {
    const inv = await this.tools.linkedin.listReceivedInvitations({
      channelId,
      limit: 20,
    });
    const invLinks = inv.invitations.map((i) =>
      buildInvitationLink(channelId, i, true)
    );
    if (invLinks.length > 0) {
      await this.tools.integrations.saveLinks(invLinks);
    }

    const { links } = await backfillChats({
      tool: this.tools.linkedin,
      provider: PROVIDER_KEY,
      channelId,
      groupType: TYPE_CONVERSATION,
      onAttachmentMessage: (id) =>
        this.set(`linkedin:msg-channel:${id}`, channelId),
    });
    if (links.length > 0) {
      await this.tools.integrations.saveLinks(links);
    }

    await this.tools.integrations.channelSyncCompleted(channelId);
  }

  /**
   * Conservative paginated backfill of the connected LinkedIn account's
   * 1st-degree relations into Plot's contact table. Each call fetches one
   * page (~100 relations), saves them as contacts, and reschedules itself
   * with a 2–4h jittered delay. Stops once Unipile returns
   * `nextCursor === null` — a one-time crawl, no refresh loop. New relations
   * arrive via the `relation.new` webhook.
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
      // One-time crawl is done. Don't reschedule.
      return;
    }

    let nextCursor: string | null;
    try {
      const page = await this.tools.linkedin.listRelations({
        channelId,
        cursor: state.cursor,
        limit: RELATIONS_PAGE_LIMIT,
      });

      const contacts: NewContact[] = page.relations.map((p) =>
        profileToContact(p)
      );

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
        // One-time crawl complete — stop. No refresh reschedule.
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
      const link = await buildLinkForChat({
        tool: this.tools.linkedin,
        provider: PROVIDER_KEY,
        channelId,
        chat,
        initialSync: false,
        groupType: TYPE_CONVERSATION,
        onAttachmentMessage: (id) =>
          this.set(`linkedin:msg-channel:${id}`, channelId),
      });
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
    if (draft.type !== TYPE_CONVERSATION) return null;

    // Resolve recipient ids (LinkedIn provider_id / URN) from the
    // pre-resolved recipients list. For `compose.targets: "contacts"` link
    // types the runtime populates `draft.recipients` with `externalAccountId`
    // values from `contact_external_account` rows keyed on the LinkedIn
    // provider.
    const recipients = draft.recipients ?? [];
    if (recipients.length === 0) {
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

    // 1:1 compose returns a person-keyed link so it converges with the synced
    // conversation thread (fixes the old chat-keyed `dm` duplicate-thread bug).
    // Multi-person compose stays chat-keyed.
    const isGroup = recipientIds.length > 1;
    const firstId = recipientIds[0]!;
    return {
      source: isGroup ? `linkedin:chat:${chatId}` : `linkedin:person:${firstId}`,
      sources: isGroup
        ? [`linkedin:chat:${chatId}`]
        : [`linkedin:person:${firstId}`, `linkedin:chat:${chatId}`],
      type: TYPE_CONVERSATION,
      status: STATUS_INBOX,
      title: draft.title,
      created: message.sentAt,
      channelId,
      meta: {
        syncProvider: PROVIDER_KEY,
        channelId,
        chatId,
        ...(isGroup ? {} : { profileId: firstId }),
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
        a.type === ActionType.file,
    );

    const attachments: Array<{
      buffer: Uint8Array;
      filename: string;
      mimeType: string;
    }> = [];
    for (const action of fileActions) {
      try {
        const file = await this.tools.files.read(action.fileId);
        attachments.push({
          buffer: file.data,
          filename: file.fileName,
          mimeType: file.mimeType,
        });
      } catch (e) {
        console.error("LinkedIn attachment read failed", action.fileId, e);
      }
    }

    const sent = await this.tools.linkedin.sendMessage({
      channelId,
      chatId,
      // LinkedIn DMs are plain text — strip Markdown so the recipient sees
      // clean text (e.g. "bold", not "**bold**") instead of literal syntax.
      text: markdownToPlainText(note.content ?? ""),
      attachments: attachments.length > 0 ? attachments : undefined,
    });
    return {
      key: `message-${sent.id}`,
      externalContent: sent.text,
    };
  }

  /**
   * Pushes a single emoji add/remove the user made in Plot back to LinkedIn,
   * attributed to that user (dispatched on their own connector instance via
   * `twist_instance_for_actor`, so the Unipile call runs under their account).
   *
   * LinkedIn allows each member at most one reaction per message and only the
   * seven `LINKEDIN_REACTIONS`. We track the emoji we last pushed for this
   * user/message in connector state (`reaction_sent:${messageId}`, which is
   * per-user since this runs on the user's instance) and reconcile via
   * `reconcilePerUserReaction`. Removal is best effort —
   * `LinkedInMessaging.clearMessageReaction` swallows `404/405`.
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
    const decision = reconcilePerUserReaction(lastSent, emoji, added, LINKEDIN_REACTIONS);
    if (decision.action === "none") return;

    try {
      if (decision.action === "set") {
        await this.tools.linkedin.setMessageReaction({
          channelId,
          messageId,
          reaction: decision.emoji,
        });
        await this.set(stateKey, decision.emoji);
      } else {
        await this.tools.linkedin.clearMessageReaction({ channelId, messageId });
        await this.clear(stateKey);
      }
    } catch (error) {
      console.warn(
        `LinkedIn reaction write-back failed for message ${messageId}`,
        error
      );
    }
  }

  override async onLinkUpdated(link: Link): Promise<void> {
    if (link.type !== TYPE_CONVERSATION) return;

    const meta = (link.meta ?? {}) as Record<string, unknown>;
    const channelId    = meta.channelId    as string | undefined;
    const invitationId = meta.invitationId as string | undefined;
    const sharedSecret = meta.sharedSecret as string | undefined;
    if (!channelId) return;
    if (!invitationId || !sharedSecret) return; // chat-only link — nothing to write back

    // Idempotency: each invitation can only be accepted once. Plot may
    // re-fire onLinkUpdated on unrelated edits (notes, title, etc.).
    const flagKey = `invitation_writeback:${invitationId}`;
    if (await this.get<string>(flagKey)) return;

    // The only write-back is accept: moving a pending invitation to
    // "Connected" (inbox) in Plot accepts it on LinkedIn. There is no
    // ignore/archive status anymore, so other transitions are no-ops.
    if (link.status !== STATUS_INBOX) return;

    try {
      await this.tools.linkedin.acceptInvitation({
        channelId,
        invitationId,
        sharedSecret,
      });
      await this.set(flagKey, "accept");
    } catch (error) {
      // Invitation may have been resolved out-of-band; record the attempt so
      // we don't retry a stale invitation on every subsequent edit.
      console.warn(
        `LinkedIn invitation write-back failed (${invitationId}, accept)`,
        error
      );
      await this.set(flagKey, "accept");
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

  override async downloadAttachment(ref: string): Promise<
    | { redirectUrl: string }
    | { body: ReadableStream | Uint8Array; mimeType: string; fileName?: string }
  > {
    const colon = ref.indexOf(":");
    if (colon < 0) throw new Error(`Invalid LinkedIn attachment ref: ${ref}`);
    const messageId = ref.slice(0, colon);
    const attachmentId = ref.slice(colon + 1);

    const channelId = await this.get<string>(`linkedin:msg-channel:${messageId}`);
    if (!channelId) {
      throw new Error(
        `No LinkedIn channel cached for message ${messageId}. ` +
          `The message may not have been synced through this connector instance.`
      );
    }

    const result = await this.tools.linkedin.downloadAttachment({
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

export default LinkedIn;

/**
 * Build a person-keyed `conversation` link for an inbound LinkedIn connection
 * request (invitation). The `pending` status is only set on initial sync —
 * incremental polls may see a still-pending invitation for a propagation
 * window after the user accepts in Plot; overwriting status would undo their
 * accept. LinkedIn-specific (invitations have no analogue on WhatsApp/
 * Instagram), so this helper stays local; profile→contact uses the shared
 * `profileToContact`.
 */
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
    ...(initialSync ? { status: STATUS_PENDING } : {}),
    title: inv.inviter.name,
    preview: inv.message ?? inv.inviter.subtitle ?? null,
    sourceUrl: inv.inviter.profileUrl,
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
