import {
  Connector,
  type CreateLinkDraft,
  type NoteWriteBackResult,
  type ToolBuilder,
} from "@plotday/twister";
import type { Actor, NewLinkWithNotes, Note, Thread } from "@plotday/twister/plot";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Files } from "@plotday/twister/tools/files";

import { OUTLOOK_PEOPLE_SCOPES } from "./enrich";
import {
  getOutlookMailChannels,
  OUTLOOK_MAIL_LINK_TYPES,
  OUTLOOK_MAIL_SCOPES,
} from "./channels";
import { GraphMailApi } from "./graph-mail-api";
import {
  type InitialSyncState,
  type OutlookMailSyncHost,
  type SubscriptionState,
  INCREMENTAL_SYNC_COALESCE_MS,
  INCREMENTAL_SYNC_TASK_KEY,
  SELF_HEAL_INTERVAL_MS,
  addEnabledChannelFn,
  queueIncrementalSyncFn,
  downloadAttachmentFn,
  ensureMailboxSubscriptionFn,
  getApiFn,
  getEnabledChannelsFn,
  getMailboxRenewalSchedule,
  incrementalSyncBatchFn,
  initialSyncBatchFn,
  onCreateLinkFn,
  onNoteCreatedFn,
  onOutlookMailWebhookFn,
  onThreadReadFn,
  onThreadToDoFn,
  pickChannelForConversation,
  recipientsFor,
  recoverMailboxDeliveryFn,
  removeEnabledChannelFn,
  renewMailboxSubscriptionFn,
  selfHealCheckFn,
  setupMailboxSubscriptionFn,
  teardownMailboxSubscriptionFn,
} from "./sync";

// Re-export the pure helpers so existing imports (and tests that import them
// from "./outlook-mail") keep working unchanged.
export { pickChannelForConversation, recipientsFor };

/**
 * Microsoft Outlook Mail connector.
 *
 * Channels are mail folders; enabling one backfills its history. Ongoing
 * changes arrive through a single mailbox-wide Graph change-notification
 * subscription on `/me/messages`, with an hourly per-folder delta-query
 * self-heal sweeping up anything push delivery missed.
 *
 * The sync, send, subscription, and self-heal logic lives in `./sync` as
 * standalone functions over an {@link OutlookMailSyncHost}; this class is a
 * thin connector that builds a host from `this`, owns all scheduling, and
 * delegates the rest (mirrors @plotday/connector-gmail).
 *
 * **Required OAuth Scopes:**
 * - `Mail.ReadWrite` — read folders/messages, update read + flag state, drafts
 * - `Mail.Send` — send replies and new mail composed in Plot
 * - `People.Read` / `Contacts.Read` — display-name enrichment (best-effort)
 */
export class OutlookMail extends Connector<OutlookMail> {
  static readonly PROVIDER = AuthProvider.Microsoft;
  static readonly handleReplies = true;
  static readonly SCOPES = OUTLOOK_MAIL_SCOPES;

  readonly provider = AuthProvider.Microsoft;
  readonly channelNoun = { singular: "folder", plural: "folders" };
  // Merge in People/Contacts scopes so email-only contacts (Graph messages
  // carry name + address but nothing else) can be enriched with display
  // names from the user's People/Contacts data.
  readonly scopes = Integrations.MergeScopes(
    OUTLOOK_MAIL_SCOPES,
    OUTLOOK_PEOPLE_SCOPES
  );
  readonly access = [
    "Reads your email so Plot can turn messages into threads and tasks",
    "Sends replies, creates drafts, and updates messages from Plot",
    "Reads your contacts to recognise senders by name",
  ];
  readonly linkTypes = OUTLOOK_MAIL_LINK_TYPES;

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: ["https://graph.microsoft.com/*"],
      }),
      files: build(Files),
    };
  }

  // ---------------------------------------------------------------------------
  // Host wrapper + public state delegators
  //
  // The Connector base class exposes set/get/clear (and `id`) as `protected`,
  // but OutlookMailSyncHost requires them as public. We bridge this via a host
  // object that delegates through the public wrapper methods below. The host's
  // `scheduler` section routes back to this connector's own scheduling methods
  // (which remain here so they reference `this.callback`/`this.scheduleRecurring`
  // and stay interceptable by tests).
  // ---------------------------------------------------------------------------

  /** Public set wrapper so the host object can expose it. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _hostSet(key: string, value: any): Promise<void> {
    return this.set(key, value);
  }
  /** Public bulk-set wrapper so the host object can expose it. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _hostSetMany(entries: [key: string, value: any][]): Promise<void> {
    return this.setMany(entries);
  }
  /** Public get wrapper so the host object can expose it. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _hostGet<T = any>(key: string): Promise<T | null> {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return this.get<any>(key);
  }
  /** Public clear wrapper so the host object can expose it. */
  _hostClear(key: string): Promise<void> {
    return this.clear(key);
  }

  /**
   * Returns an OutlookMailSyncHost backed by this connector instance.
   * Passes through all tool access, exposes set/get/clear + id as public
   * members, and binds the scheduler section to this connector's own methods.
   */
  private makeHost(): OutlookMailSyncHost {
    const self = this;
    return {
      id: self.id,
      set: (key, value) => self._hostSet(key, value),
      setMany: (entries) => self._hostSetMany(entries),
      get: <T>(key: string) => self._hostGet<T>(key),
      clear: (key) => self._hostClear(key),
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      tools: self.tools as any,
      scheduler: {
        onOutlookMailWebhook: self.onOutlookMailWebhook,
        setupMailboxSubscription: () => self.setupMailboxSubscription(),
        renewMailboxSubscription: () => self.renewMailboxSubscription(),
        scheduleMailboxRenewal: (expiration) =>
          self.scheduleMailboxRenewal(expiration),
        scheduleSelfHealCheck: () => self.scheduleSelfHealCheck(),
        cancelScheduledTask: (key) => self.cancelScheduledTask(key),
        scheduleIncrementalSyncDrain: () =>
          self.scheduleIncrementalSyncDrain(),
        queueRenewSubscription: () => self.queueRenewSubscription(),
        requeueInitialSync: (channelId) => self.requeueInitialSync(channelId),
      },
    };
  }

  override async upgrade(): Promise<void> {
    // Durable recovery backstop, run on every deploy. Re-asserts recurring
    // maintenance for a healthy mailbox and re-establishes (plus backfills) a
    // stranded one. See recoverMailboxDelivery for the stranded cases.
    await this.recoverMailboxDelivery();
  }

  /**
   * Ensure live push delivery + recurring maintenance for any instance with
   * enabled channels. Runs from upgrade() on every deploy. Delegates to
   * {@link recoverMailboxDeliveryFn}; the scheduling it triggers routes back
   * through the host's scheduler section.
   */
  private async recoverMailboxDelivery(): Promise<void> {
    await recoverMailboxDeliveryFn(this.makeHost());
  }

  /**
   * Re-queue a fresh full backfill of one folder, dropping any stale cursors
   * (initial + delta) so the walk restarts and the delta baseline reseeds.
   * Used by recovery to re-import mail that arrived while push delivery was
   * dead.
   */
  private async requeueInitialSync(channelId: string): Promise<void> {
    await this.set<InitialSyncState>(`initial_state_${channelId}`, {});
    await this.clear(`delta_${channelId}`);
    const initial = await this.callback(this.initialSyncBatch, channelId, 1);
    await this.runTask(initial);
  }

  override async activate(context: {
    auth: Authorization;
    actor: Actor;
  }): Promise<void> {
    await this.set("auth_actor_id", context.actor.id);
  }

  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    return getOutlookMailChannels(token);
  }

  async onChannelEnabled(
    channel: Channel,
    context?: SyncContext
  ): Promise<void> {
    const syncHistoryMin = context?.syncHistoryMin;
    if (context?.recovering) {
      // Recovery dispatch after re-auth: drop the per-channel cursors so
      // this channel re-walks its folder and the delta baseline reseeds.
      await this.clear(`initial_state_${channel.id}`);
      await this.clear(`delta_${channel.id}`);
    } else if (syncHistoryMin) {
      // Skip when stored window is already at least as wide. Bypassed on
      // recovery so the recovery pass re-walks even when the window
      // hasn't widened.
      const storedMin = await this.get<string>(
        `sync_history_min_${channel.id}`
      );
      if (storedMin && new Date(storedMin) <= syncHistoryMin) {
        return;
      }
      await this.set(
        `sync_history_min_${channel.id}`,
        syncHistoryMin.toISOString()
      );
    }

    await this.addEnabledChannel(channel.id);

    // observeOnly: the channel is being auto-observed because a user composed
    // a Plot thread into it, not explicitly enabled. We still register the
    // mailbox subscription below so inbound events sync back, but skip the
    // historical backfill — the user didn't ask to import this folder's
    // history.
    if (!context?.observeOnly) {
      const initialState: InitialSyncState = {
        lastSyncTime: syncHistoryMin ?? undefined,
      };
      await this.set(`initial_state_${channel.id}`, initialState);

      const initialCallback = await this.callback(
        this.initialSyncBatch,
        channel.id,
        1
      );
      await this.runTask(initialCallback);
    }

    // Queue mailbox-wide subscription setup as a separate task to avoid
    // blocking the HTTP response. ensureMailboxSubscription is idempotent.
    const subscriptionCallback = await this.callback(
      this.ensureMailboxSubscription
    );
    await this.runTask(subscriptionCallback);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.removeEnabledChannel(channel.id);
    await this.clear(`initial_state_${channel.id}`);
    await this.clear(`sync_history_min_${channel.id}`);
    await this.clear(`delta_${channel.id}`);

    // If no enabled channels remain, tear the subscription down. The next
    // onChannelEnabled will rebuild it.
    const enabled = await this.getEnabledChannels();
    if (enabled.size === 0) {
      await this.teardownMailboxSubscription();
    }
  }

  /** Legacy entry point kept for interface parity with gmail. */
  async startSync(options: { channelId: string; timeMin?: Date }): Promise<void> {
    const { channelId, timeMin } = options;
    await this.set(`initial_state_${channelId}`, {
      lastSyncTime: timeMin ?? undefined,
    } satisfies InitialSyncState);
    await this.addEnabledChannel(channelId);
    await this.runTask(await this.callback(this.initialSyncBatch, channelId, 1));
    await this.runTask(await this.callback(this.ensureMailboxSubscription));
  }

  async stopSync(channelId: string): Promise<void> {
    await this.removeEnabledChannel(channelId);
    await this.clear(`initial_state_${channelId}`);
    await this.clear(`delta_${channelId}`);
    const enabled = await this.getEnabledChannels();
    if (enabled.size === 0) {
      await this.teardownMailboxSubscription();
    }
  }

  // Auth + channel helpers ---------------------------------------------------

  private async getApi(channelId: string): Promise<GraphMailApi> {
    return getApiFn(this.makeHost(), channelId);
  }

  /** Returns the set of channelIds the user currently has enabled. */
  private async getEnabledChannels(): Promise<Set<string>> {
    return getEnabledChannelsFn(this.makeHost());
  }

  private async addEnabledChannel(channelId: string): Promise<void> {
    return addEnabledChannelFn(this.makeHost(), channelId);
  }

  private async removeEnabledChannel(channelId: string): Promise<void> {
    return removeEnabledChannelFn(this.makeHost(), channelId);
  }

  // Subscription lifecycle ----------------------------------------------------

  /**
   * Idempotently set up the mailbox-wide Graph subscription. Delegates to
   * {@link ensureMailboxSubscriptionFn}; the scheduling it triggers routes
   * back through the host's scheduler section.
   */
  async ensureMailboxSubscription(): Promise<void> {
    await ensureMailboxSubscriptionFn(this.makeHost());
  }

  private async setupMailboxSubscription(): Promise<void> {
    await setupMailboxSubscriptionFn(this.makeHost());
  }

  /**
   * Cancel renewal + self-heal tasks, delete the Graph subscription and the
   * webhook token, and clear all subscription state. Called when the last
   * channel is disabled. Delegates to {@link teardownMailboxSubscriptionFn}.
   */
  private async teardownMailboxSubscription(): Promise<void> {
    await teardownMailboxSubscriptionFn(this.makeHost());
  }

  /** Schedules subscription renewal RENEWAL_LEAD_MS before expiry. */
  private async scheduleMailboxRenewal(expiration: Date): Promise<void> {
    const renewalCallback = await this.callback(this.renewMailboxSubscription);
    await this.scheduleRecurring(
      "mailbox-subscription-renewal",
      renewalCallback,
      getMailboxRenewalSchedule(expiration)
    );
  }

  /**
   * Renews the Graph subscription before it expires. Delegates to
   * {@link renewMailboxSubscriptionFn}; see that function for the full
   * fallback behavior.
   */
  async renewMailboxSubscription(): Promise<void> {
    await renewMailboxSubscriptionFn(this.makeHost());
  }

  /**
   * (Re)schedules the self-heal check as a durable recurring task.
   * Idempotent: scheduling under the same key replaces any existing task.
   */
  private async scheduleSelfHealCheck(): Promise<void> {
    const callback = await this.callback(this.selfHealCheck);
    await this.scheduleRecurring("mailbox-self-heal", callback, {
      intervalMs: SELF_HEAL_INTERVAL_MS,
    });
  }

  /**
   * Periodic safety net. Delegates to {@link selfHealCheckFn}; see that
   * function for the full behavior.
   */
  async selfHealCheck(): Promise<void> {
    await selfHealCheckFn(this.makeHost());
  }

  // Sync pipeline --------------------------------------------------------------

  /**
   * Per-channel initial backfill. Delegates to {@link initialSyncBatchFn} and
   * schedules the next batch when more pages remain.
   */
  async initialSyncBatch(channelId: string, batchNumber: number): Promise<void> {
    const result = await initialSyncBatchFn(
      this.makeHost(),
      channelId,
      batchNumber
    );
    if ("done" in result) return;
    const next = await this.callback(
      this.initialSyncBatch,
      channelId,
      result.next.batchNumber
    );
    await this.runTask(next);
  }

  /**
   * Graph change-notification handler (synchronous webhook). Delegates the
   * validation handshake + clientState verification to
   * {@link onOutlookMailWebhookFn}; the caller owns queuing the follow-up
   * tasks (subscription renewal and/or incremental sync).
   */
  async onOutlookMailWebhook(request: WebhookRequest): Promise<string | void> {
    const result = await onOutlookMailWebhookFn(this.makeHost(), request);
    if ("validationToken" in result) return result.validationToken;
    if ("done" in result) return;
    if (result.queueRenewSubscription) {
      await this.queueRenewSubscription();
    }
    if (result.queueIncrementalSync) {
      await this.queueIncrementalSync(result.messageIds);
    }
  }

  /**
   * Record notified message ids and schedule the coalesced drain. Graph
   * sends one change notification per message; enqueueing an immediate task
   * per notification flooded the queue during active mail traffic, and the
   * batched passes stacked into one worker until it exceeded the memory
   * limit. Ids are persisted per-key first (race-free under concurrent
   * deliveries), then a burst collapses into a single drain pass.
   */
  private async queueIncrementalSync(messageIds: string[]): Promise<void> {
    await queueIncrementalSyncFn(this.makeHost(), messageIds);
  }

  /** Schedule the coalesced incremental drain (host scheduler hook). */
  private async scheduleIncrementalSyncDrain(): Promise<void> {
    const callback = await this.callback(this.incrementalSyncBatch, []);
    await this.scheduleTask(INCREMENTAL_SYNC_TASK_KEY, callback, {
      runAt: new Date(Date.now() + INCREMENTAL_SYNC_COALESCE_MS),
      coalesce: true,
    });
  }

  /** Queue a subscription renewal as a task (host scheduler hook). */
  private async queueRenewSubscription(): Promise<void> {
    await this.runTask(await this.callback(this.renewMailboxSubscription));
  }

  /**
   * Mailbox-wide incremental sync over a set of notified message ids.
   * Delegates entirely to {@link incrementalSyncBatchFn}.
   */
  async incrementalSyncBatch(messageIds: string[]): Promise<void> {
    await incrementalSyncBatchFn(this.makeHost(), messageIds);
  }

  // Two-way status sync ---------------------------------------------------------

  async onThreadRead(
    thread: Thread,
    actor: Actor,
    unread: boolean
  ): Promise<void> {
    await onThreadReadFn(this.makeHost(), thread, actor, unread);
  }

  async onThreadToDo(
    thread: Thread,
    actor: Actor,
    todo: boolean,
    options: { date?: Date }
  ): Promise<void> {
    await onThreadToDoFn(this.makeHost(), thread, actor, todo, options);
  }

  // Reply + compose ---------------------------------------------------------------

  async onNoteCreated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    return onNoteCreatedFn(this.makeHost(), note, thread);
  }

  /**
   * Creates a new outbound email from Plot. Delegates to {@link onCreateLinkFn}.
   */
  override async onCreateLink(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    return onCreateLinkFn(this.makeHost(), draft);
  }

  /**
   * Downloads an attachment identified by the opaque `ref` emitted during
   * inbound sync. Delegates to {@link downloadAttachmentFn}.
   */
  override async downloadAttachment(ref: string): Promise<
    | { redirectUrl: string }
    | { body: Uint8Array; mimeType: string; fileName?: string }
  > {
    return downloadAttachmentFn(this.makeHost(), ref);
  }
}

export default OutlookMail;
