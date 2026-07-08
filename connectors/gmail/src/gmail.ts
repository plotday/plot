import {
  Connector,
  type CreateLinkDraft,
  type NoteWriteBackResult,
  type ToolBuilder,
} from "@plotday/twister";
import type { Actor, CreateLinkResult, Note, Thread } from "@plotday/twister/plot";
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

import { GOOGLE_PEOPLE_SCOPES } from "@plotday/connector-google-contacts";

import { GmailApi, type GmailThread, type SyncState } from "./gmail-api";
import { GMAIL_LINK_TYPES, getGmailChannels } from "./channels";
import {
  type GmailSyncHost,
  type InitialSyncState,
  type MailboxWebhookState,
  addEnabledChannelFn,
  downloadAttachmentFn,
  ensureMailboxWebhookFn,
  getApiFn,
  getEnabledChannelsFn,
  getMailboxRenewalSchedule,
  incrementalSyncBatchFn,
  initialSyncBatchFn,
  onCreateLinkFn,
  onGmailWebhookFn,
  onNoteCreatedFn,
  onThreadReadFn,
  onThreadToDoFn,
  processEmailThreadsFn,
  processWriteBackRetryFn,
  removeEnabledChannelFn,
  renewMailboxWatchFn,
  selfHealCheckFn,
  setupMailboxWebhookFn,
  teardownMailboxWebhookFn,
  INCREMENTAL_SYNC_COALESCE_MS,
  INCREMENTAL_SYNC_TASK_KEY,
  SELF_HEAL_INTERVAL_MS,
  SYSTEM_LABEL_ORDER,
  WRITEBACK_RETRY_DELAY_MS,
} from "./sync";

// Re-export the pure recipient helper so existing imports (and tests that
// import it from "./gmail") keep working unchanged.

type MessageChannel = {
  id: string;
  name: string;
  description: string | null;
  primary: boolean;
};

type MessageSyncOptions = {
  timeMin?: Date;
};

/**
 * Gmail integration source implementing the MessagingSource interface.
 *
 * Supports inbox, labels, and search filters as channels.
 * Auth is managed declaratively via provider config in build() and
 * handled through the twist edit modal.
 *
 * **Required OAuth Scope:**
 * - `https://www.googleapis.com/auth/gmail.modify` - Read messages, modify labels, send replies
 *
 * `gmail.modify` is a superset that grants all read/write operations except
 * permanent delete, so it covers reading threads, archiving, label changes,
 * and sending replies without needing `gmail.readonly` or `gmail.send`.
 *
 * The sync, send, and watch logic lives in `./sync` as standalone functions
 * over a {@link GmailSyncHost}; this class is a thin connector that builds a
 * host from `this`, owns all scheduling, and delegates the rest.
 */
export class Gmail extends Connector<Gmail> {
  static readonly PROVIDER = AuthProvider.Google;
  static readonly handleReplies = true;
  static readonly SCOPES = ["https://www.googleapis.com/auth/gmail.modify"];

  readonly provider = AuthProvider.Google;
  readonly channelNoun = { singular: "label", plural: "labels" };
  // Merge in People API scopes so we can enrich email-only contacts (Gmail
  // headers carry name + address but no avatar) with photos from the user's
  // Google Contacts and "other contacts" — without requiring the separate
  // Google Contacts connector to be installed.
  readonly scopes = Integrations.MergeScopes(
    Gmail.SCOPES,
    GOOGLE_PEOPLE_SCOPES,
  );
  readonly access = [
    "Reads your email so Plot can turn messages into threads and tasks",
    "Sends replies, creates drafts, and updates labels and read state from Plot",
    "Reads your contacts to recognise senders by name and photo",
  ];
  readonly linkTypes = GMAIL_LINK_TYPES;

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: [
          "https://gmail.googleapis.com/gmail/v1/*",
          "https://people.googleapis.com/v1/*",
          "https://www.googleapis.com/oauth2/v3/userinfo",
        ],
      }),
      files: build(Files),
    };
  }

  // ---------------------------------------------------------------------------
  // Host wrapper + public state delegators
  //
  // The Connector base class exposes set/get/clear (and `id`) as `protected`,
  // but GmailSyncHost requires them as public. We bridge this via a host
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
   * Returns a GmailSyncHost backed by this connector instance.
   * Passes through all tool access, exposes set/get/clear + id as public
   * members, and binds the scheduler section to this connector's own methods.
   */
  private makeHost(): GmailSyncHost {
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
        onGmailWebhook: self.onGmailWebhook,
        setupMailboxWebhook: () => self.setupMailboxWebhook(),
        renewMailboxWatch: () => self.renewMailboxWatch(),
        scheduleMailboxRenewal: (expiration) =>
          self.scheduleMailboxRenewal(expiration),
        scheduleSelfHealCheck: () => self.scheduleSelfHealCheck(),
        cancelScheduledTask: (key) => self.cancelScheduledTask(key),
        queueIncrementalSync: () => self.queueIncrementalSync(),
        queueWriteBackRetry: () => self.queueWriteBackRetry(),
      },
    };
  }

  override async activate(context: { auth: Authorization; actor: Actor }): Promise<void> {
    await this.set("auth_actor_id", context.actor.id);
  }

  override async upgrade(): Promise<void> {
    // `mailbox_webhook` is the canonical "already on the mailbox-wide watch
    // model" sentinel. Instances that predate that change still carry old
    // per-channel keys and need a one-time migration before recovery runs.
    const migrated = await this.get<MailboxWebhookState>("mailbox_webhook");
    if (!migrated) {
      await this.migrateLegacyPerChannelState();
    }

    // Durable recovery backstop, run on every deploy. Re-asserts recurring
    // maintenance for a healthy mailbox and re-establishes (plus backfills) a
    // stranded one. See recoverMailboxDelivery for the stranded cases.
    await this.recoverMailboxDelivery();
  }

  /**
   * Ensure live push delivery + recurring maintenance for any instance with
   * enabled channels. Runs from upgrade() on every deploy.
   *
   * Two stranded states were previously unrecoverable — neither the old
   * `if (mailbox_webhook) re-assert` upgrade path nor the cron maintenance
   * sweep could heal them, so the connection stayed silently dead until the
   * user manually re-enabled a channel:
   *
   *   1. `mailbox_webhook` never persisted — a prior `setupWatch()` threw
   *      before its `set()` (e.g. the Gmail "Only one user push notification
   *      client allowed per developer" 400). With no sentinel there was
   *      nothing to re-assert, and because `scheduleRecurring` never ran the
   *      maintenance sweep's `ever` marker was never set either; and
   *   2. the watch expired while the self-heal/renewal chain was dead.
   *
   * A healthy watch (present and unexpired) only re-asserts the recurring
   * tasks. A missing or expired watch is re-established AND every enabled label
   * is re-walked, so mail that accumulated while delivery was dead is
   * backfilled. The backfill upserts by `source` (no duplicates) and uses
   * initial-sync semantics (read/unarchived), so it never spams notifications.
   */
  private async recoverMailboxDelivery(): Promise<void> {
    const enabled = await this.getEnabledChannels();
    if (enabled.size === 0) return;

    const webhook = await this.get<MailboxWebhookState>("mailbox_webhook");
    if (webhook && new Date(webhook.expiration).getTime() > Date.now()) {
      // Healthy watch — re-assert durable maintenance (idempotent, keyed).
      try {
        await this.scheduleSelfHealCheck();
        await this.scheduleMailboxRenewal(new Date(webhook.expiration));
      } catch (error) {
        console.error(
          `Gmail upgrade [${this.id}]: failed to re-assert recurring tasks`,
          error
        );
      }
      return;
    }

    // Stranded: watch missing or expired with nothing live renewing it.
    try {
      for (const channelId of enabled) {
        await this.requeueInitialSync(channelId);
      }
      await this.setupMailboxWebhook();
    } catch (error) {
      console.error(
        `Gmail upgrade [${this.id}]: stranded-mailbox recovery failed`,
        error
      );
    }
  }

  /**
   * Re-queue a fresh full backfill of one label, dropping any stale cursor so
   * the walk restarts from the newest thread. Used by recovery to re-import
   * mail that arrived while push delivery was dead.
   */
  private async requeueInitialSync(channelId: string): Promise<void> {
    await this.set<InitialSyncState>(`initial_state_${channelId}`, {});
    const initial = await this.callback(this.initialSyncBatch, channelId, 1);
    await this.runTask(initial);
  }

  /**
   * One-time migration from per-channel watches to a single mailbox-wide watch.
   *
   * Old layout (per-channel):
   *   - `channel_webhook_${id}`, `watch_renewal_task_${id}`, `sync_state_${id}`,
   *     `sync_enabled_${id}`
   * New layout (per-twist-instance):
   *   - `mailbox_webhook`, `incremental_state`, `enabled_channels`, plus
   *     `initial_state_${id}` for in-flight backfills; recurring tasks are
   *     keyed "mailbox-watch-renewal" and "mailbox-self-heal"
   *
   * The Twist runtime API doesn't let connectors enumerate stored keys, so we
   * probe the system labels we know users can enable. Users with custom
   * Gmail labels enabled (e.g. `Label_14`) will need to re-toggle them after
   * this upgrade — without `list()` we can't discover their IDs. The mailbox
   * watch itself is (re-)established afterward by recoverMailboxDelivery().
   */
  private async migrateLegacyPerChannelState(): Promise<void> {
    // Stop whatever per-channel watch was last active. Gmail allows only
    // one watch per mailbox, so a single stopWatch() call covers all of
    // them — but the call needs an authed API client.
    const stopApi = await this.findAnyAuthApi();
    if (stopApi) {
      try {
        await stopApi.stopWatch();
      } catch {
        // Best effort — old watch may have already expired.
      }
    }

    // Probe known system labels for old per-channel state and migrate.
    for (const labelId of SYSTEM_LABEL_ORDER) {
      const oldWebhook = await this.get<{ topicName?: string }>(
        `channel_webhook_${labelId}`
      );
      const oldEnabled = await this.get<boolean>(`sync_enabled_${labelId}`);
      const oldSyncState = await this.get<SyncState>(`sync_state_${labelId}`);
      const oldRenewalTask = await this.get<string>(
        `watch_renewal_task_${labelId}`
      );

      if (
        !oldWebhook &&
        !oldEnabled &&
        !oldSyncState &&
        !oldRenewalTask
      ) {
        continue;
      }

      // Channel was enabled (presence of any old per-channel key counts).
      if (oldEnabled || oldWebhook) {
        await this.addEnabledChannel(labelId);
      }

      // Carry over any in-flight initial-backfill cursor.
      if (oldSyncState?.pageToken) {
        await this.set<InitialSyncState>(`initial_state_${labelId}`, {
          pageToken: oldSyncState.pageToken,
          lastSyncTime: oldSyncState.lastSyncTime,
        });
        // Resume the backfill under the new callback.
        const next = await this.callback(this.initialSyncBatch, labelId, 1);
        await this.runTask(next);
      }

      // Cancel old per-channel renewal task.
      if (oldRenewalTask) {
        try {
          await this.cancelTask(oldRenewalTask);
        } catch {
          // Task may have already executed.
        }
        await this.clear(`watch_renewal_task_${labelId}`);
      }

      // Clean up old per-channel topic. The topic still receives no
      // notifications (Gmail's mailbox watch points elsewhere now), but
      // leaving it dangling wastes Pub/Sub resources.
      if (oldWebhook?.topicName) {
        try {
          await this.tools.network.deleteWebhook(oldWebhook.topicName);
        } catch (error) {
          console.warn(
            `Failed to delete old per-channel webhook ${labelId}:`,
            error
          );
        }
      }
      await this.clear(`channel_webhook_${labelId}`);
      await this.clear(`sync_state_${labelId}`);
      await this.clear(`sync_enabled_${labelId}`);
    }
  }

  private async findAnyAuthApi(): Promise<GmailApi | null> {
    // Try known system labels and any already-migrated channels in the new
    // enabled_channels list. Per-channel auth is just the Google account
    // token, so any channelId works.
    const candidates = new Set<string>(SYSTEM_LABEL_ORDER);
    for (const id of await this.getEnabledChannels()) candidates.add(id);
    for (const channelId of candidates) {
      try {
        const token = await this.tools.integrations.get(channelId);
        if (token?.token) return new GmailApi(token.token);
      } catch {
        // Channel unknown to integrations — skip.
      }
    }
    return null;
  }

  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    return getGmailChannels(token);
  }

  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    const syncHistoryMin = context?.syncHistoryMin;
    if (context?.recovering) {
      // Recovery dispatch after re-auth: drop the per-channel initial
      // cursor so this channel re-walks its label. Don't touch
      // `incremental_state` here — the mailbox-wide cursor is shared
      // across all channels, and incrementalSyncBatch already self-heals
      // a stale (>7 day) historyId via the 404 → reseed path.
      await this.clear(`initial_state_${channel.id}`);
    } else if (syncHistoryMin) {
      // Skip when stored window is already at least as wide. Bypassed on
      // recovery so the recovery pass re-walks even when the window
      // hasn't widened.
      const storedMin = await this.get<string>(`sync_history_min_${channel.id}`);
      if (storedMin && new Date(storedMin) <= syncHistoryMin) {
        return;
      }
      await this.set(`sync_history_min_${channel.id}`, syncHistoryMin.toISOString());
    }

    await this.addEnabledChannel(channel.id);

    // observeOnly: the channel is being auto-observed because a user composed
    // a Plot thread into it, not explicitly enabled. We still register the
    // mailbox watch below so inbound events sync back, but skip the historical
    // backfill — the user didn't ask to import this mailbox's history.
    if (!context?.observeOnly) {
      const initialState: InitialSyncState = {
        lastSyncTime: syncHistoryMin ?? undefined,
        // Bounds the backfill walk itself (Gmail `after:` query) — without
        // it the walk pages the whole mailbox and the server discards
        // everything older than the window after it was already fetched.
        historyFloor: syncHistoryMin ?? undefined,
      };
      await this.set(`initial_state_${channel.id}`, initialState);

      // Queue per-channel initial backfill (label-scoped paginated thread list)
      // as a separate task so onChannelEnabled returns quickly.
      const initialCallback = await this.callback(
        this.initialSyncBatch,
        channel.id,
        1
      );
      await this.runTask(initialCallback);
    }

    // Queue mailbox-wide webhook setup as a separate task to avoid blocking
    // the HTTP response. ensureMailboxWebhook is idempotent: if the watch
    // already exists from a previously-enabled channel, this is a no-op
    // beyond bumping the renewal cadence.
    const webhookCallback = await this.callback(this.ensureMailboxWebhook);
    await this.runTask(webhookCallback);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.removeEnabledChannel(channel.id);
    await this.clear(`initial_state_${channel.id}`);
    await this.clear(`sync_history_min_${channel.id}`);

    // If no enabled channels remain, tear the mailbox watch down. The next
    // onChannelEnabled will rebuild it.
    const enabled = await this.getEnabledChannels();
    if (enabled.size === 0) {
      await this.teardownMailboxWebhook();
    }
  }

  private async getApi(channelId: string): Promise<GmailApi> {
    return getApiFn(this.makeHost(), channelId);
  }

  async listLabels(channelId: string): Promise<MessageChannel[]> {
    const api = await this.getApi(channelId);
    const labels = await api.getLabels();

    const channels: MessageChannel[] = [];

    // Add standard labels as channels
    for (const label of labels) {
      // Filter out system labels that don't make sense as channels
      if (
        label.type === "system" &&
        !["INBOX", "SENT", "DRAFT", "IMPORTANT", "STARRED"].includes(label.id)
      ) {
        continue;
      }

      channels.push({
        id: label.id,
        name: label.name,
        description: `${label.messagesTotal || 0} messages, ${
          label.messagesUnread || 0
        } unread`,
        primary: label.id === "INBOX",
      });
    }

    // Add a special "search" channel option
    channels.push({
      id: "search:from:important@example.com",
      name: "Search (Custom Query)",
      description: "Use custom Gmail search queries as channels",
      primary: false,
    });

    return channels;
  }

  async startSync(
    options: {
      channelId: string;
    } & MessageSyncOptions
  ): Promise<void> {
    const { channelId, timeMin } = options;

    const initialState: InitialSyncState = {
      lastSyncTime: timeMin
        ? typeof timeMin === "string"
          ? new Date(timeMin)
          : timeMin
        : undefined,
    };

    await this.set(`initial_state_${channelId}`, initialState);
    await this.addEnabledChannel(channelId);

    const initialCallback = await this.callback(
      this.initialSyncBatch,
      channelId,
      1
    );
    await this.runTask(initialCallback);

    const webhookCallback = await this.callback(this.ensureMailboxWebhook);
    await this.runTask(webhookCallback);
  }

  async stopSync(channelId: string): Promise<void> {
    await this.removeEnabledChannel(channelId);
    await this.clear(`initial_state_${channelId}`);

    // Tear down the mailbox watch only if this was the last enabled channel.
    const enabled = await this.getEnabledChannels();
    if (enabled.size === 0) {
      await this.teardownMailboxWebhook();
    }
  }

  // ---------------------------------------------------------------------------
  // Mailbox watch lifecycle — scheduling stays on the connector
  // ---------------------------------------------------------------------------

  /**
   * Idempotently set up the mailbox-wide Gmail watch + Pub/Sub topic.
   * Delegates the data-plane work to {@link ensureMailboxWebhookFn}; the
   * scheduling it triggers routes back through the host's scheduler section.
   */
  async ensureMailboxWebhook(): Promise<void> {
    await ensureMailboxWebhookFn(this.makeHost());
  }

  private async setupMailboxWebhook(): Promise<void> {
    await setupMailboxWebhookFn(this.makeHost());
  }

  /**
   * Cancel renewal, stop the Gmail watch, delete the Pub/Sub topic, and
   * clear all mailbox-watch state. Called when the last channel is disabled
   * (and from preUpgrade for stale per-channel state).
   */
  private async teardownMailboxWebhook(): Promise<void> {
    await teardownMailboxWebhookFn(this.makeHost());
  }

  /**
   * Schedules a durable recurring task to renew the Gmail watch before its
   * 7-day expiry. The ceiling (3.5 days) ensures the watch is renewed even
   * if a precise renewal beat is missed. firstRunAt tightens the next run to
   * 1 day before the current expiration. Idempotent — keyed replace.
   */
  private async scheduleMailboxRenewal(expiration: Date): Promise<void> {
    const renewalCallback = await this.callback(this.renewMailboxWatch);
    // Ceiling = 3.5 days (half the 7-day Gmail watch): even if a precise
    // renewal beat is lost, the watch is renewed well before it expires.
    // The platform clamps a past firstRunAt to now, so no immediate-renew
    // branch is needed.
    await this.scheduleRecurring(
      "mailbox-watch-renewal",
      renewalCallback,
      getMailboxRenewalSchedule(expiration)
    );
  }

  /**
   * Renews the Gmail mailbox watch before it expires. On primary-path
   * failure, falls back to a full mailbox-webhook re-setup. If both paths
   * fail the error is rethrown so the runtime captures it in PostHog —
   * `selfHealCheck` is the safety net that retries on the next interval.
   */
  async renewMailboxWatch(): Promise<void> {
    await renewMailboxWatchFn(this.makeHost());
  }

  /**
   * Periodic safety net for the mailbox watch. Delegates to
   * {@link selfHealCheckFn}; see that function for the full behavior.
   */
  async selfHealCheck(): Promise<void> {
    await selfHealCheckFn(this.makeHost());
  }

  /**
   * (Re)schedules the next self-heal check as a durable recurring task.
   * The platform re-arms it every SELF_HEAL_INTERVAL_MS — the callback no
   * longer reschedules itself. Idempotent: keyed replace, so concurrent
   * calls replace rather than leak.
   */
  private async scheduleSelfHealCheck(): Promise<void> {
    const callback = await this.callback(this.selfHealCheck);
    await this.scheduleRecurring("mailbox-self-heal", callback, {
      intervalMs: SELF_HEAL_INTERVAL_MS,
    });
  }

  // ---------------------------------------------------------------------------
  // Sync batches — delegate to extracted state machine, own the scheduling
  // ---------------------------------------------------------------------------

  /**
   * Per-channel initial backfill. Delegates to {@link initialSyncBatchFn} and
   * schedules the next batch when more pages remain.
   */
  async initialSyncBatch(
    channelId: string,
    batchNumber: number
  ): Promise<void> {
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
   * Mailbox-wide incremental sync. Triggered from a Pub/Sub webhook.
   * Delegates entirely to {@link incrementalSyncBatchFn} (no further
   * scheduling — a single pass drains the whole history window).
   */
  async incrementalSyncBatch(_ids: string[] = []): Promise<void> {
    await incrementalSyncBatchFn(this.makeHost());
  }

  /**
   * Schedule the mailbox-wide incremental sync (host scheduler hook). Keyed +
   * coalescing: Gmail pushes one Pub/Sub notification per mailbox change, so
   * enqueueing an immediate task per call flooded the queue during active
   * traffic and the batched passes stacked into one worker isolate until it
   * exceeded the memory limit. A notification burst now collapses into a
   * single pass that fires within {@link INCREMENTAL_SYNC_COALESCE_MS}.
   */
  private async queueIncrementalSync(): Promise<void> {
    // Signal-only drain: Gmail's history cursor (not the notification) is
    // the source of work, so no ids are recorded — the platform just
    // guarantees one coalesced pass.
    await this.scheduleDrain(
      INCREMENTAL_SYNC_TASK_KEY,
      this.incrementalSyncBatch,
      { delayMs: INCREMENTAL_SYNC_COALESCE_MS }
    );
  }

  /**
   * Drain deferred (quota-exhausted) write-backs. Delegates to
   * {@link processWriteBackRetryFn}, which re-queues itself while work remains.
   */
  async writeBackRetryBatch(): Promise<void> {
    await processWriteBackRetryFn(this.makeHost());
  }

  /**
   * Schedule the deferred write-back drain (host scheduler hook). Keyed +
   * delayed via `scheduleTask` so repeated enqueues during a quota burst
   * collapse to a single task that fires after the per-minute window clears —
   * it never hot-loops the way an immediate `runTask` self-chain would.
   */
  private async queueWriteBackRetry(): Promise<void> {
    const callback = await this.callback(this.writeBackRetryBatch);
    await this.scheduleTask("gmail-writeback-retry", callback, {
      runAt: new Date(Date.now() + WRITEBACK_RETRY_DELAY_MS),
    });
  }

  /**
   * Backwards-compatible shim for callbacks deployed under the old
   * per-channel sync architecture. New deploys should never produce this
   * callback; this exists so already-queued callbacks finish gracefully.
   */
  async syncBatch(
    _batchNumber: number,
    mode: "full" | "incremental",
    channelId: string,
    _initialSync?: boolean
  ): Promise<void> {
    if (mode === "full") {
      // Forward to the new per-channel initial backfill. Seed the cursor
      // so initialSyncBatch has something to read.
      const existing = await this.get<InitialSyncState>(
        `initial_state_${channelId}`
      );
      if (!existing) {
        await this.set<InitialSyncState>(`initial_state_${channelId}`, {});
      }
      await this.initialSyncBatch(channelId, 1);
      return;
    }
    // Old "incremental" callback — forward to mailbox-wide sync.
    await this.incrementalSyncBatch();
  }

  /**
   * Backwards-compatible shim for callbacks deployed under the old
   * per-channel webhook architecture. Forwards to mailbox-wide setup.
   */
  async setupChannelWebhook(_channelId: string): Promise<void> {
    await this.ensureMailboxWebhook();
  }

  /**
   * Backwards-compatible shim for old per-channel watch-renewal tasks.
   */
  async renewWatch(_channelId: string): Promise<void> {
    await this.renewMailboxWatch();
  }

  /**
   * Process a batch of synced Gmail threads (transform → enrich → save +
   * two-way read/star sync). Thin delegator to {@link processEmailThreadsFn}.
   */
  private async processEmailThreads(
    threads: GmailThread[],
    initialSync: boolean,
    forceChannelId?: string
  ): Promise<void> {
    await processEmailThreadsFn(
      this.makeHost(),
      threads,
      initialSync,
      forceChannelId
    );
  }

  // ---------------------------------------------------------------------------
  // Framework callbacks — outbound write-back + webhook
  // ---------------------------------------------------------------------------

  async onNoteCreated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    return onNoteCreatedFn(this.makeHost(), note, thread);
  }

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

  /**
   * Creates a new outbound email from Plot. Delegates to {@link onCreateLinkFn}.
   */
  override async onCreateLink(
    draft: CreateLinkDraft
  ): Promise<CreateLinkResult | null> {
    return onCreateLinkFn(this.makeHost(), draft);
  }

  /**
   * Pub/Sub webhook handler. Single mailbox-wide watch → single handler.
   * Delegates the decode + cursor-seed logic to {@link onGmailWebhookFn}; the
   * caller owns queuing the incremental sync task.
   *
   * The optional `_channelId` argument exists for backwards compatibility
   * with already-deployed per-channel webhook callbacks (which were
   * registered with `extraArgs: [channelId]`). The new mailbox-wide watch
   * registers without extraArgs, so newer deploys never pass a channelId.
   */
  async onGmailWebhook(
    request: WebhookRequest,
    _channelId?: string
  ): Promise<void> {
    const result = await onGmailWebhookFn(this.makeHost(), request);
    if ("done" in result) return;
    await this.queueIncrementalSync();
  }

  /**
   * Downloads an attachment from Gmail identified by the opaque `ref` string
   * emitted during inbound sync. Delegates to {@link downloadAttachmentFn}.
   */
  override async downloadAttachment(ref: string): Promise<
    | { redirectUrl: string }
    | { body: Uint8Array; mimeType: string; fileName?: string }
  > {
    return downloadAttachmentFn(this.makeHost(), ref);
  }

  // Helpers ------------------------------------------------------------------

  /** Returns the set of channelIds the user currently has enabled. */
  private async getEnabledChannels(): Promise<Set<string>> {
    return getEnabledChannelsFn(this.makeHost());
  }

  /** Add a channelId to the enabled set (idempotent, preserves order). */
  private async addEnabledChannel(channelId: string): Promise<void> {
    return addEnabledChannelFn(this.makeHost(), channelId);
  }

  /** Remove a channelId from the enabled set. */
  private async removeEnabledChannel(channelId: string): Promise<void> {
    return removeEnabledChannelFn(this.makeHost(), channelId);
  }
}

export default Gmail;
