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
  accountIdFromChannel,
  adaptivePollDelayMs,
  backfillChats,
  buildCommentNote,
  buildLinkForChat,
  buildPostBodyNote,
  buildPostLink,
  commentNoteKey,
  type LinkedInComment,
  type LinkedInInvitation,
  type LinkedInPost,
  type LinkedInPostReaction,
  LINKEDIN_POST_REACTIONS,
  LinkedInMessaging,
  mapEmojiToPostReactionType,
  postBodyNoteKey,
  postsChannelId,
  profileToContact,
  reconcilePerUserReaction,
} from "@plotday/unipile";

// LinkedIn has a single composable link type: `conversation` covers 1:1 AND
// multi-person chats, and an inbound connection request (invitation) is the
// `pending` status on that same type. There is no named-group entity on
// LinkedIn messaging — a chat is just its participant set — so multi-person
// chats are `conversation` links whose `accessContacts` has >1 entry.
const TYPE_CONVERSATION = "conversation";

// Public Post channel: a `post` link is the connected account's own LinkedIn
// post plus its comments/reactions. Distinct link type from `conversation`
// since posts have no chat/invitation semantics.
const TYPE_POST = "post";
// Number of comments/reactions fetched per poll page.
const COMMENT_PAGE_LIMIT = 50;
// Discovery poll cadence for natively-created posts (jittered).
const DISCOVER_MIN_MS = 60 * 60 * 1000; // 1h
const DISCOVER_MAX_MS = 2 * 60 * 60 * 1000; // 2h
// Initial import + discovery look-back window.
const IMPORT_WINDOW_MS = 7 * 24 * 60 * 60 * 1000; // past week (initial)
const DISCOVER_WINDOW_MS = 30 * 24 * 60 * 60 * 1000; // 30 days (ongoing)

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

// Link type config for the Public Post channel. `sharingModel: "thread"`
// (rather than "channel") is used so the single-participant (self) roster
// the connector sets is respected; there is no external membership to
// derive.
const POST_LINK_TYPE = {
  type: TYPE_POST,
  label: "Post",
  sourceName: "LinkedIn",
  sharingModel: "thread" as const,
  noteLabel: "Comment",
  replyPlaceholder: "Add a comment",
  replyVerb: "Comment",
  composePlaceholder: "Write a public LinkedIn post",
  composeVerb: "Post",
  supportsFileAttachments: true,
  reactionCapabilities: { mode: "fixed" as const, allowed: LINKEDIN_POST_REACTIONS },
  logo: "https://api.iconify.design/logos/linkedin-icon.svg",
  logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
  compose: { targets: "channels" as const },
};

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
    const accountId = token.token;
    const name = auth?.actor.name ?? "LinkedIn";
    return [
      // Messages: unchanged id (accountId) + connector-level `conversation` type.
      { id: accountId, title: name },
      // Public Post: opt-in, its own `post` link type.
      {
        id: postsChannelId(accountId),
        title: "Public Post",
        enabledByDefault: false,
        linkTypes: [POST_LINK_TYPE],
      },
    ];
  }

  async onChannelEnabled(channel: Channel): Promise<void> {
    if (channel.id.endsWith("#posts")) {
      await this.onPostChannelEnabled(channel.id);
      return;
    }

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

  /**
   * Public Post channel enable: import the past week of the account's own
   * posts (with comments), mark the channel's sync complete, then kick off
   * per-post comment polling and the ongoing discovery loop.
   */
  private async onPostChannelEnabled(channelId: string): Promise<void> {
    await this.set(`posts_enabled_${channelId}`, true);

    // Initial import: the past week of the account's own posts, with comments.
    const cutoff = Date.now() - IMPORT_WINDOW_MS;
    let cursor: string | null = null;
    const recentPostIds: string[] = [];
    for (let page = 0; page < 10; page++) {
      const { posts, nextCursor } = await this.tools.linkedin.listOwnPosts({ channelId, cursor, limit: 20 });
      let reachedOld = false;
      for (const post of posts) {
        if (post.createdAt.getTime() < cutoff) { reachedOld = true; continue; }
        await this.importPost(channelId, post, true);
        recentPostIds.push(post.id);
      }
      cursor = nextCursor;
      if (!cursor || reachedOld) break;
    }

    await this.tools.integrations.channelSyncCompleted(channelId);

    // Kick off each imported post's comment poll, then the discovery loop.
    for (const postId of recentPostIds) {
      const t = await this.callback(this.pollPostComments, channelId, postId);
      await this.runTask(t);
    }
    const discover = await this.callback(this.discoverPosts, channelId);
    await this.runTask(discover, { runAt: new Date(Date.now() + DISCOVER_MIN_MS) });
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    if (channel.id.endsWith("#posts")) {
      await this.clear(`posts_enabled_${channel.id}`);
      return;
    }

    await this.clear(`webhook_callback_${channel.id}`);
    await this.clear(`relations_state_${channel.id}`);
  }

  /**
   * Fetch a post's comments and save it as a thread. `known_post_${id}` marks
   * it discovered so the discovery loop doesn't re-import.
   */
  private async importPost(channelId: string, post: LinkedInPost, initialSync: boolean): Promise<void> {
    const accountId = accountIdFromChannel(channelId);
    const comments = await this.fetchAllComments(channelId, post.id);
    const link = buildPostLink({ accountId, channelId, post, comments, initialSync });
    await this.tools.integrations.saveLinks([link]);
    await this.set(`known_post_${post.id}`, { createdAt: post.createdAt.getTime() });
  }

  private async fetchAllComments(channelId: string, postId: string): Promise<LinkedInComment[]> {
    const out: LinkedInComment[] = [];
    let cursor: string | null = null;
    for (let page = 0; page < 20; page++) {
      const { comments, nextCursor } = await this.tools.linkedin.listComments({ channelId, postId, cursor, limit: COMMENT_PAGE_LIMIT });
      out.push(...comments);
      cursor = nextCursor;
      if (!cursor) break;
    }
    return out;
  }

  /** Fetch up to 50 reactors for a post or comment. Bounded so a viral post
   * can't materialize thousands of contacts. Best-effort — returns [] on error. */
  private async fetchReactions(channelId: string, socialId: string): Promise<LinkedInPostReaction[]> {
    try {
      const { reactions } = await this.tools.linkedin.listPostReactions({ channelId, socialId, limit: 50 });
      return reactions;
    } catch (error) {
      console.warn(`LinkedIn reaction fetch failed for ${socialId}`, error);
      return [];
    }
  }

  /** Find natively-created posts (Unipile has no post webhook) and import any
   * not already known. Reschedules itself on a 1–2h jitter while enabled. */
  async discoverPosts(channelId: string): Promise<void> {
    if (!(await this.get(`posts_enabled_${channelId}`))) return; // channel disabled → stop
    try {
      const cutoff = Date.now() - DISCOVER_WINDOW_MS;
      let cursor: string | null = null;
      const newPostIds: string[] = [];
      for (let page = 0; page < 10; page++) {
        const { posts, nextCursor } = await this.tools.linkedin.listOwnPosts({ channelId, cursor, limit: 20 });
        let reachedOld = false;
        for (const post of posts) {
          if (post.createdAt.getTime() < cutoff) { reachedOld = true; continue; }
          if (await this.get(`known_post_${post.id}`)) continue;
          await this.importPost(channelId, post, false);
          newPostIds.push(post.id);
        }
        cursor = nextCursor;
        if (!cursor || reachedOld) break;
      }
      for (const postId of newPostIds) {
        const t = await this.callback(this.pollPostComments, channelId, postId);
        await this.runTask(t);
      }
    } catch (error) {
      console.warn(`LinkedIn post discovery failed for ${channelId}`, error);
    }
    // Reschedule regardless (unless disabled, checked at top of next run).
    const delay = DISCOVER_MIN_MS + Math.random() * (DISCOVER_MAX_MS - DISCOVER_MIN_MS);
    const next = await this.callback(this.discoverPosts, channelId);
    await this.runTask(next, { runAt: new Date(Date.now() + delay) });
  }

  /** Poll one post's comments, upsert new ones, and reschedule by post age.
   * Retires (no reschedule) once the post is >30 days old. */
  async pollPostComments(channelId: string, postId: string): Promise<void> {
    if (!(await this.get(`posts_enabled_${channelId}`))) return; // channel disabled → stop

    const known = await this.get<{ createdAt: number }>(`known_post_${postId}`);
    const createdAt = known ? new Date(known.createdAt) : new Date();

    try {
      const comments = await this.fetchAllComments(channelId, postId);
      const postReactions = await this.fetchReactions(channelId, postId);

      const notes: NewNote[] = [];
      if (postReactions.length > 0) {
        // Reflect post reactions onto the post-body note. Emit the FULL body
        // note (content + author + created via getPost) — NOT a content-less
        // note — so the upsert's is-distinct checks stay false and only the
        // reactions merge. A content-less note would omit author/created and
        // clobber them on every poll.
        const post = await this.tools.linkedin.getPost({ channelId, postId });
        if (post) notes.push(buildPostBodyNote(post, postReactions));
      }
      for (const c of comments) {
        const cr = await this.fetchReactions(channelId, c.id);
        notes.push(buildCommentNote(postId, c, cr));
      }

      if (notes.length > 0) {
        await this.tools.integrations.saveLinks([
          {
            source: `linkedin:post:${postId}`,
            sources: [`linkedin:post:${postId}`],
            type: TYPE_POST,
            channelId,
            meta: { syncProvider: PROVIDER_KEY, accountId: accountIdFromChannel(channelId), channelId, postId },
            notes,
          },
        ]);
      }
    } catch (error) {
      console.warn(`LinkedIn comment poll failed for post ${postId}`, error);
    }

    const delay = adaptivePollDelayMs(createdAt, new Date());
    if (delay === null) return; // retire
    const jittered = delay + Math.random() * delay * 0.2;
    const next = await this.callback(this.pollPostComments, channelId, postId);
    await this.runTask(next, { runAt: new Date(Date.now() + jittered) });
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
    if (draft.type === TYPE_POST) {
      const text = markdownToPlainText((draft.noteContent ?? draft.title ?? "").trim());
      if (!text) {
        console.error("[linkedin] onCreateLink(post): empty body; cannot post.");
        return null;
      }
      const channelId = draft.channelId;
      const attachments: Array<{
        buffer: Uint8Array;
        filename: string;
        mimeType: string;
      }> = [];
      for (const a of draft.attachments ?? []) {
        try {
          const file = await this.tools.files.read(a.fileId);
          attachments.push({
            buffer: file.data,
            filename: file.fileName,
            mimeType: file.mimeType,
          });
        } catch (e) {
          console.error("LinkedIn post attachment read failed", a.fileId, e);
        }
      }
      const { postId } = await this.tools.linkedin.createPost({
        channelId,
        text,
        attachments: attachments.length > 0 ? attachments : undefined,
      });
      if (!postId) {
        console.error("[linkedin] onCreateLink(post): no post id returned.");
        return null;
      }
      const accountId = accountIdFromChannel(channelId);
      await this.set(`known_post_${postId}`, { createdAt: Date.now() });
      // Start this post's comment poll.
      const t = await this.callback(this.pollPostComments, channelId, postId);
      await this.runTask(t, { runAt: new Date(Date.now() + 5 * 60 * 1000) });
      return {
        source: `linkedin:post:${postId}`,
        sources: [`linkedin:post:${postId}`],
        type: TYPE_POST,
        title: draft.title,
        created: new Date(),
        channelId,
        // Rekey the composed thread's opening note to the post-body key so the
        // skip guard in onNoteCreated recognizes it and doesn't re-post the body
        // as a comment. (saveCreatedLink → updateNoteBaseline sets the key; same
        // pattern as the Slack connector's createChannelPost.)
        originatingNote: { key: postBodyNoteKey(postId), externalContent: text },
        meta: { syncProvider: PROVIDER_KEY, accountId, channelId, postId },
      } satisfies NewLinkWithNotes;
    }

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
    const meta0 = (thread.meta ?? {}) as Record<string, unknown>;
    const postId = meta0.postId as string | undefined;
    if (postId) {
      const channelId = meta0.channelId as string | undefined;
      if (!channelId) return;
      // The post body note is authored via onCreateLink's returned link, not a
      // reply — skip it so we don't comment our own post text.
      if (note.key === postBodyNoteKey(postId)) return;
      const text = markdownToPlainText(note.content ?? "");
      if (!text) return;

      // reNoteKey (runtime-resolved) is the key of the note this reply targets.
      // A comment key → nested reply; the post-body key or absent → top-level.
      const reNoteKey = meta0.reNoteKey as string | undefined;
      let parentCommentId: string | null = null;
      if (reNoteKey && reNoteKey.startsWith("comment-")) {
        parentCommentId = reNoteKey.slice("comment-".length);
      }

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
          console.error("LinkedIn comment attachment read failed", action.fileId, e);
        }
      }

      const { commentId } = await this.tools.linkedin.createComment({
        channelId, postId, text, parentCommentId,
        attachments: attachments.length > 0 ? attachments : undefined,
      });
      return { key: `comment-${commentId}`, externalContent: text };
    }

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
    const pmeta = (thread.meta ?? {}) as Record<string, unknown>;
    const postId = pmeta.postId as string | undefined;
    if (postId) {
      const channelId = pmeta.channelId as string | undefined;
      if (!channelId) return;
      // socialId: the comment id for a comment note, else the post id.
      const socialId = note.key && note.key.startsWith("comment-")
        ? note.key.slice("comment-".length)
        : postId;

      const stateKey = `post_reaction_sent:${socialId}`;
      const lastSent = (await this.get<string>(stateKey)) ?? null;
      const decision = reconcilePerUserReaction(lastSent, emoji, added, LINKEDIN_POST_REACTIONS);
      if (decision.action === "none") return;
      try {
        if (decision.action === "set") {
          const reactionType = mapEmojiToPostReactionType(decision.emoji);
          if (!reactionType) return;
          await this.tools.linkedin.reactToPost({ channelId, socialId, reactionType });
          await this.set(stateKey, decision.emoji);
        } else {
          await this.tools.linkedin.unreactToPost({ channelId, socialId });
          await this.clear(stateKey);
        }
      } catch (error) {
        console.warn(`LinkedIn post reaction write-back failed for ${socialId}`, error);
      }
      return;
    }

    const meta = (thread.meta ?? {}) as Record<string, unknown>;
    const channelId = meta.channelId as string | undefined;
    const chatId = meta.chatId as string | undefined;
    if (!channelId || !chatId) return;
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
          chatId,
          messageId,
          reaction: decision.emoji,
        });
        await this.set(stateKey, decision.emoji);
      } else {
        await this.tools.linkedin.clearMessageReaction({ channelId, chatId, messageId });
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
    if (!channelId) return;
    if (!invitationId) return; // chat-only link — nothing to write back

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
    },
    ...(initialSync ? { unread: false, archived: false } : {}),
  } satisfies NewLinkWithNotes;
}
