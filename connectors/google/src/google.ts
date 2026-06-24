import GoogleContacts, {
  type ContactsSyncHost,
  onChannelEnabledFn as contactsOnChannelEnabledFn,
  onChannelDisabledFn as contactsOnChannelDisabledFn,
  syncBatchFn as contactsSyncBatchFn,
} from "@plotday/connector-google-contacts";
import {
  type CalendarSyncHost,
  clearBuffersFn,
  extractRSVPParamsFn,
  getWatchRenewalScheduleFn,
  resolveCalendarIdFn,
  runCalendarInit,
  runSyncBatch,
  setupCalendarWatchFn,
  startIncrementalSyncFn,
  stopCalendarWatchFn,
  updateEventRSVPWithApiFn,
  validateCalendarWebhookFn,
  getApiFn,
} from "@plotday/connector-google-calendar";
import {
  type GmailSyncHost,
  type InitialSyncState,
  ensureMailboxWebhookFn,
  setupMailboxWebhookFn,
  teardownMailboxWebhookFn,
  renewMailboxWatchFn,
  selfHealCheckFn,
  getMailboxRenewalSchedule,
  initialSyncBatchFn,
  incrementalSyncBatchFn,
  onNoteCreatedFn,
  onThreadReadFn,
  onThreadToDoFn,
  onCreateLinkFn,
  onGmailWebhookFn,
  downloadAttachmentFn,
  getEnabledChannelsFn,
  addEnabledChannelFn,
  removeEnabledChannelFn,
  SELF_HEAL_INTERVAL_MS,
} from "@plotday/connector-gmail";
import {
  type TasksSyncHost,
  POLL_INTERVAL_MS,
  POLL_RECURRING_INTERVAL_MS,
  onChannelEnabledFn as tasksOnChannelEnabledFn,
  onChannelDisabledFn as tasksOnChannelDisabledFn,
  syncBatchFn as tasksSyncBatchFn,
  periodicSyncFn as tasksPeriodicSyncFn,
  periodicSyncBatchFn as tasksPeriodicSyncBatchFn,
  onCreateLinkFn as tasksOnCreateLinkFn,
  onLinkUpdatedFn as tasksOnLinkUpdatedFn,
} from "@plotday/connector-google-tasks";
import { Connector } from "@plotday/twister";
import type {
  Actor,
  ActorId,
  CreateLinkDraft,
  Link,
  NoteWriteBackResult,
  Thread,
  ToolBuilder,
} from "@plotday/twister";
import type { NewLinkWithNotes, Note } from "@plotday/twister/plot";
import type { ScheduleContactStatus } from "@plotday/twister/schedule";
import {
  AuthProvider,
  Integrations,
  type Authorization,
  type AuthToken,
  type Channel,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Files } from "@plotday/twister/tools/files";

import { GOOGLE_SCOPES, PRODUCTS } from "./scopes";
import { composeChannels, resolveProductForChannelId } from "./compose";
import { parse } from "./product-channel";
import { PRODUCTS_BY_KEY } from "./products/product";

/**
 * Combined Google connector: Mail, Calendar, Tasks, and Contacts under a
 * single OAuth grant. Calendar channels are handled directly by this class
 * (with `calendar:` key namespacing); other products delegate to their
 * respective product modules.
 */
export class Google extends Connector<Google> {
  readonly provider = AuthProvider.Google;

  readonly dynamicLinkTypes = true;

  readonly scopes = GOOGLE_SCOPES;

  /**
   * Per-product metadata for the combined-connection setup/status UX. Each
   * entry's `scopeGroupId` matches an `OptionalScopeGroup.id` in GOOGLE_SCOPES,
   * so the API can derive per-product enablement from granted scopes +
   * enabled channels.
   */
  readonly products = PRODUCTS;

  readonly channelNoun = { singular: "channel", plural: "channels" };

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: [
          "https://www.googleapis.com/calendar/*",
          "https://gmail.googleapis.com/gmail/v1/*",
          "https://people.googleapis.com/v1/*",
          "https://tasks.googleapis.com/*",
        ],
      }),
      googleContacts: build(GoogleContacts),
      files: build(Files),
    };
  }

  /**
   * Records the connecting user's actor id so Mail + Tasks sync can attribute
   * synced threads/tasks to the account owner. Stored under each product's key
   * namespace, matching what the extracted sync reads via its host.
   */
  override async activate(context: {
    auth: Authorization;
    actor: Actor;
  }): Promise<void> {
    await this.makeMailHost().set("auth_actor_id", context.actor.id);
    await this.makeTasksHost().set("auth_actor_id", context.actor.id);
  }

  async getChannels(
    _auth: Authorization | null,
    token: AuthToken | null
  ): Promise<Channel[]> {
    if (!token) return [];
    return composeChannels(Object.values(PRODUCTS_BY_KEY), token);
  }

  async onChannelEnabled(
    channel: Channel,
    context?: SyncContext
  ): Promise<void> {
    const { product: productKey, rawId } = parse(channel.id);

    if (productKey === "calendar") {
      await this.onCalendarChannelEnabled(rawId, context);
      return;
    }

    if (productKey === "mail") {
      await this.onMailChannelEnabled(rawId, context);
      return;
    }

    if (productKey === "tasks") {
      await this.onTasksChannelEnabled(rawId, context);
      return;
    }

    if (productKey === "contacts") {
      await this.onContactsChannelEnabled(rawId);
      return;
    }

    const product = resolveProductForChannelId(
      Object.values(PRODUCTS_BY_KEY),
      channel.id
    );
    if (!product) return;
    await product.onEnable(rawId, context);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    const { product: productKey, rawId } = parse(channel.id);

    if (productKey === "calendar") {
      await this.stopCalendarSync(rawId);
      return;
    }

    if (productKey === "mail") {
      await this.stopMailSync(rawId);
      return;
    }

    if (productKey === "tasks") {
      await tasksOnChannelDisabledFn(this.makeTasksHost(), rawId);
      return;
    }

    if (productKey === "contacts") {
      await contactsOnChannelDisabledFn(this.makeContactsHost(), rawId);
      return;
    }

    const product = resolveProductForChannelId(
      Object.values(PRODUCTS_BY_KEY),
      channel.id
    );
    if (!product) return;
    await product.onDisable(rawId);
  }

  // ---------------------------------------------------------------------------
  // RSVP write-back (dispatched by the runtime to the acting user's instance)
  // ---------------------------------------------------------------------------

  /**
   * Called when the user updates their RSVP for an event. Routes by the
   * thread's `meta.syncableId` (the calendar id, which uses the `calendar:`
   * namespace on this connector). Falls back to link-type routing for
   * threads without a syncableId.
   */
  async onScheduleContactUpdated(
    thread: Thread,
    _scheduleId: string,
    _contactId: ActorId,
    status: ScheduleContactStatus | null,
    _actor: Actor
  ): Promise<void> {
    const params = extractRSVPParamsFn(thread, status);
    if (!params) return;

    const { calendarId, eventId, googleStatus } = params;
    const host = this.makeCalendarHost();

    try {
      const api = await getApiFn(host, calendarId);
      await updateEventRSVPWithApiFn(api, calendarId, eventId, googleStatus);
    } catch (error) {
      console.error("[RSVP Sync] Failed to sync RSVP", {
        event_id: eventId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Host wrapper (prefixes all storage keys with "calendar:")
  // ---------------------------------------------------------------------------

  /**
   * Public set proxy so makeCalendarHost() can wrap `this` through a
   * CalendarSyncHost interface (which requires public methods).
   */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _calendarHostSet(key: string, value: any): Promise<void> {
    return this.set(`calendar:${key}`, value);
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _calendarHostGet<T = any>(key: string): Promise<T | null> {
    return this.get<any>(`calendar:${key}`);
  }
  _calendarHostClear(key: string): Promise<void> {
    return this.clear(`calendar:${key}`);
  }

  /**
   * Returns a CalendarSyncHost that namespaces every storage key under
   * `calendar:` so calendar state can't collide with mail/tasks keys.
   *
   * The store.list proxy also strips the `calendar:` prefix from results
   * so the extracted functions see consistent un-prefixed keys.
   */
  private makeCalendarHost(): CalendarSyncHost {
    const self = this;
    return {
      set: (key, value) => self._calendarHostSet(key, value),
      get: <T>(key: string) => self._calendarHostGet<T>(key),
      clear: (key) => self._calendarHostClear(key),
      tools: {
        integrations: self.tools.integrations as any,
        googleContacts: self.tools.googleContacts,
        store: {
          acquireLock: (key, ttlMs) =>
            self.tools.store.acquireLock(`calendar:${key}`, ttlMs),
          releaseLock: (key) =>
            self.tools.store.releaseLock(`calendar:${key}`),
          /**
           * Lists prefixed keys and strips the `calendar:` prefix from
           * the returned paths so callers can use them as-is with
           * host.get/host.clear (which will re-add the prefix).
           */
          list: async (prefix) => {
            const keys = await self.tools.store.list(`calendar:${prefix}`);
            return keys.map((k) =>
              k.startsWith("calendar:") ? k.slice("calendar:".length) : k
            );
          },
        },
      },
    };
  }

  // ---------------------------------------------------------------------------
  // Calendar lifecycle methods (dispatched callbacks — must live on this class)
  // ---------------------------------------------------------------------------

  /**
   * Pre-init logic for a calendar channel: recovery state wipe, history-min
   * window check, then queue `calendarInit` as a task.
   */
  private async onCalendarChannelEnabled(
    rawId: string,
    context?: SyncContext
  ): Promise<void> {
    const host = this.makeCalendarHost();

    // Resolve "primary" to the actual calendar id for recovery clearing.
    // Mirrors what GoogleCalendar.onChannelEnabled does.
    const resolvedCalendarId = await resolveCalendarIdFn(host, rawId);

    if (context?.recovering) {
      await host.clear(`last_sync_token_${resolvedCalendarId}`);
      await host.clear(`last_sync_token_${rawId}`);
      await host.clear(`sync_state_${resolvedCalendarId}`);
      await host.tools.store.releaseLock(`sync_${resolvedCalendarId}`);
      await clearBuffersFn(host, resolvedCalendarId);
    } else if (context?.syncHistoryMin) {
      const key = `sync_history_min_${rawId}`;
      const stored = await host.get<string>(key);
      if (stored && new Date(stored) <= context.syncHistoryMin) {
        return; // Already synced with equal or earlier history min
      }
      await host.set(key, context.syncHistoryMin.toISOString());
    }

    const initCallback = await this.callback(this.calendarInit, rawId);
    await this.runTask(initCallback);
  }

  /**
   * Initializes a calendar channel: resolves the calendar ID, acquires the
   * sync lock, sets the initial SyncState, sets up the push webhook, and
   * queues the first batch.
   */
  async calendarInit(calendarId: string): Promise<void> {
    const host = this.makeCalendarHost();
    const result = await runCalendarInit(host, calendarId);
    if ("done" in result) return;

    const { resolvedCalendarId, batchNumber, mode, initialSync } = result.next;

    // Set up the push webhook for this calendar. A watch failure must never
    // abort sync setup — the calendar still populates without live updates.
    try {
      await this.calendarSetupWatch(resolvedCalendarId);
    } catch (error) {
      console.error(
        `Failed to set up calendar watch for ${resolvedCalendarId}; continuing with sync (live updates disabled until next renewal):`,
        error
      );
    }

    const syncCallback = await this.callback(
      this.calendarSyncBatch,
      batchNumber,
      mode,
      resolvedCalendarId,
      initialSync
    );
    await this.runTask(syncCallback);
  }

  /**
   * Processes one batch of calendar events and schedules the next batch.
   * Delegates to {@link runSyncBatch} with the `calendar:` namespaced host.
   */
  async calendarSyncBatch(
    batchNumber: number,
    mode: "full" | "incremental",
    calendarId: string,
    initialSync?: boolean
  ): Promise<void> {
    const host = this.makeCalendarHost();
    const result = await runSyncBatch(
      host,
      batchNumber,
      mode,
      calendarId,
      initialSync ?? false
    );
    if ("done" in result) return;
    const nextCallback = await this.callback(
      this.calendarSyncBatch,
      result.next.batchNumber,
      result.next.mode,
      calendarId,
      initialSync ?? false
    );
    await this.runTask(nextCallback);
  }

  // ---------------------------------------------------------------------------
  // Calendar watch / webhook (dispatched callbacks — must live on this class)
  // ---------------------------------------------------------------------------

  /**
   * Creates the Google Calendar push-notification watch for the given calendar.
   * Idempotent: stops any existing watch before registering a new one.
   * After success, schedules proactive renewal 24h before expiry.
   *
   * @private
   */
  private async calendarSetupWatch(calendarId: string): Promise<void> {
    // The webhook URL embeds a reference to calendarOnWebhook so the runtime
    // routes incoming push notifications directly to that method.
    const webhookUrl = await this.tools.network.createWebhook(
      {},
      this.calendarOnWebhook,
      calendarId
    );

    const result = await setupCalendarWatchFn(
      this.makeCalendarHost(),
      webhookUrl,
      calendarId
    );
    if ("skipped" in result) return;

    // Schedule proactive renewal 24h before expiry.
    await this.calendarScheduleWatchRenewal(calendarId);
  }

  /**
   * Schedules a durable recurring renewal for the calendar watch.
   * If the renewal window has already passed, renews immediately.
   *
   * @private
   */
  private async calendarScheduleWatchRenewal(calendarId: string): Promise<void> {
    const schedule = await getWatchRenewalScheduleFn(
      this.makeCalendarHost(),
      calendarId
    );
    if (!schedule) return;

    if ("immediate" in schedule) {
      await this.calendarRenewWatch(calendarId);
      return;
    }

    const renewalCallback = await this.callback(
      this.calendarRenewWatch,
      calendarId
    );
    // Durable recurring: ceiling 3.5 days (half the ~7-day watch) guarantees a
    // renewal fires even if a precise beat is lost; firstRunAt keeps the precise
    // expiry-24h timing.
    await this.scheduleRecurring(
      `calendar:watch-renewal:${calendarId}`,
      renewalCallback,
      schedule
    );
  }

  /**
   * Renews the calendar watch. Called by the scheduled renewal task and
   * reactively when a webhook arrives close to the watch expiry.
   *
   * Gracefully catches and logs errors without re-throwing.
   */
  async calendarRenewWatch(calendarId: string): Promise<void> {
    try {
      const oldWatchData = await this._calendarHostGet(
        `calendar_watch_${calendarId}`
      );
      if (!oldWatchData) {
        console.warn(
          `No watch data found for calendar ${calendarId}, skipping renewal`
        );
        return;
      }
      // calendarSetupWatch is idempotent — it stops the old watch and
      // re-schedules the keyed renewal — so no separate teardown is needed.
      await this.calendarSetupWatch(calendarId);
    } catch (error) {
      console.error(`Failed to renew watch for calendar ${calendarId}:`, error);
    }
  }

  /**
   * Receives Google Calendar push notifications for a specific calendar.
   * Validates the incoming request, optionally triggers watch renewal if near
   * expiry, then enqueues an incremental sync batch.
   *
   * The webhook URL was registered by {@link calendarSetupWatch} with `calendarId`
   * as the extra arg, so the runtime calls this method with the right calendarId.
   */
  async calendarOnWebhook(
    request: WebhookRequest,
    calendarId: string
  ): Promise<void> {
    const validation = await validateCalendarWebhookFn(
      this.makeCalendarHost(),
      request,
      calendarId
    );
    if ("invalid" in validation) return;

    if (validation.needsRenewal) {
      this.calendarRenewWatch(calendarId).catch((error) => {
        console.error(
          `Failed to reactively renew watch for ${calendarId}:`,
          error
        );
      });
    }

    await this.calendarStartIncrementalSync(calendarId);
  }

  /**
   * Acquires the sync lock and enqueues an incremental sync batch for the
   * given calendar. No-op when the lock is already held (another sync is
   * in progress).
   */
  async calendarStartIncrementalSync(calendarId: string): Promise<void> {
    const result = await startIncrementalSyncFn(
      this.makeCalendarHost(),
      calendarId
    );
    if ("done" in result) return;

    const syncCallback = await this.callback(
      this.calendarSyncBatch,
      1,
      "incremental",
      calendarId,
      false
    );
    await this.runTask(syncCallback);
  }

  // ---------------------------------------------------------------------------
  // Calendar teardown
  // ---------------------------------------------------------------------------

  /**
   * Stops all calendar sync machinery for the given calendar id:
   * cancels the renewal task, stops the Google watch, clears all stored state.
   *
   * @private
   */
  private async stopCalendarSync(calendarId: string): Promise<void> {
    const host = this.makeCalendarHost();

    // 1. Cancel the scheduled renewal task.
    await this.cancelScheduledTask(`calendar:watch-renewal:${calendarId}`);

    // 2. Stop watch via Google API (best effort).
    try {
      await stopCalendarWatchFn(host, calendarId);
    } catch (error) {
      console.warn(
        "Failed to stop calendar watch:",
        error instanceof Error ? error.message : error
      );
    }

    // 3. Clear sync-related storage and release the framework-managed lock.
    await host.clear(`calendar_watch_${calendarId}`);
    await host.clear(`sync_state_${calendarId}`);
    await host.clear(`auth_token_${calendarId}`);
    await host.tools.store.releaseLock(`sync_${calendarId}`);

    // 4. Clear pending_occ / seen_master buffers from any crashed run.
    await clearBuffersFn(host, calendarId);
  }

  // ===========================================================================
  // Mail (Gmail) — mirrors @plotday/connector-gmail. All storage keys + locks
  // are namespaced under "mail:"; scheduling (callback/scheduleRecurring/
  // cancelScheduledTask) is owned here, like the Calendar section above.
  // ===========================================================================

  /** Public set proxy so makeMailHost() can wrap `this` (host needs public). */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _mailHostSet(key: string, value: any): Promise<void> {
    return this.set(`mail:${key}`, value);
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _mailHostGet<T = any>(key: string): Promise<T | null> {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return this.get<any>(`mail:${key}`);
  }
  _mailHostClear(key: string): Promise<void> {
    return this.clear(`mail:${key}`);
  }

  /**
   * Returns a GmailSyncHost that namespaces every storage key + lock under
   * "mail:" and routes the scheduler section back to this connector's own
   * mail* methods (which own this.callback / scheduleRecurring /
   * cancelScheduledTask). Watch-renewal + self-heal task keys are NOT
   * prefixed — they're per-instance task keys (one mailbox per connection)
   * and the extracted functions pass those raw keys to cancelScheduledTask.
   */
  private makeMailHost(): GmailSyncHost {
    const self = this;
    return {
      id: self.id,
      set: (key, value) => self._mailHostSet(key, value),
      get: <T>(key: string) => self._mailHostGet<T>(key),
      clear: (key) => self._mailHostClear(key),
      tools: {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        integrations: self.tools.integrations as any,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        files: self.tools.files as any,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        network: self.tools.network as any,
        store: {
          acquireLock: (key, ttlMs) =>
            self.tools.store.acquireLock(`mail:${key}`, ttlMs),
          releaseLock: (key) => self.tools.store.releaseLock(`mail:${key}`),
          list: async (prefix) => {
            const keys = await self.tools.store.list(`mail:${prefix}`);
            return keys.map((k) =>
              k.startsWith("mail:") ? k.slice("mail:".length) : k
            );
          },
        },
      },
      scheduler: {
        onGmailWebhook: self.onGmailWebhook,
        setupMailboxWebhook: () => self.mailSetupWebhook(),
        renewMailboxWatch: () => self.mailRenewWatch(),
        scheduleMailboxRenewal: (expiration) =>
          self.mailScheduleRenewal(expiration),
        scheduleSelfHealCheck: () => self.mailScheduleSelfHeal(),
        cancelScheduledTask: (key) => self.cancelScheduledTask(key),
        queueIncrementalSync: () => self.mailQueueIncrementalSync(),
      },
    };
  }

  /**
   * Pre-init for a mail channel (raw Gmail label id): recovery / history-min
   * handling, register the channel, then queue the per-channel initial backfill
   * + the idempotent mailbox-wide webhook setup. Mirrors Gmail.onChannelEnabled.
   */
  private async onMailChannelEnabled(
    rawId: string,
    context?: SyncContext
  ): Promise<void> {
    const host = this.makeMailHost();
    const syncHistoryMin = context?.syncHistoryMin;

    if (context?.recovering) {
      await host.clear(`initial_state_${rawId}`);
    } else if (syncHistoryMin) {
      const storedMin = await host.get<string>(`sync_history_min_${rawId}`);
      if (storedMin && new Date(storedMin) <= syncHistoryMin) {
        return;
      }
      await host.set(`sync_history_min_${rawId}`, syncHistoryMin.toISOString());
    }

    await addEnabledChannelFn(host, rawId);

    // observeOnly: auto-observed (a Plot thread was composed into this label),
    // not explicitly enabled — register the watch but skip historical backfill.
    if (!context?.observeOnly) {
      const initialState: InitialSyncState = {
        lastSyncTime: syncHistoryMin ?? undefined,
      };
      await host.set(`initial_state_${rawId}`, initialState);
      const initialCallback = await this.callback(
        this.mailInitialSyncBatch,
        rawId,
        1
      );
      await this.runTask(initialCallback);
    }

    const webhookCallback = await this.callback(this.mailEnsureWebhook);
    await this.runTask(webhookCallback);
  }

  /** Teardown for a mail channel; mirrors Gmail.onChannelDisabled. */
  private async stopMailSync(rawId: string): Promise<void> {
    const host = this.makeMailHost();
    await removeEnabledChannelFn(host, rawId);
    await host.clear(`initial_state_${rawId}`);
    await host.clear(`sync_history_min_${rawId}`);

    // Tear the mailbox watch down only if this was the last enabled label.
    const enabled = await getEnabledChannelsFn(host);
    if (enabled.size === 0) {
      await this.mailTeardownWebhook();
    }
  }

  // --- Mail dispatched callbacks (must live on this class) -------------------

  /** Per-channel initial backfill; schedules the next batch when more remain. */
  async mailInitialSyncBatch(
    channelId: string,
    batchNumber: number
  ): Promise<void> {
    const result = await initialSyncBatchFn(
      this.makeMailHost(),
      channelId,
      batchNumber
    );
    if ("done" in result) return;
    const next = await this.callback(
      this.mailInitialSyncBatch,
      channelId,
      result.next.batchNumber
    );
    await this.runTask(next);
  }

  /** Mailbox-wide incremental sync (one pass drains the history window). */
  async mailIncrementalSyncBatch(): Promise<void> {
    await incrementalSyncBatchFn(this.makeMailHost());
  }

  /** Idempotently (re)establish the mailbox watch + Pub/Sub topic. */
  async mailEnsureWebhook(): Promise<void> {
    await ensureMailboxWebhookFn(this.makeMailHost());
  }

  private async mailSetupWebhook(): Promise<void> {
    await setupMailboxWebhookFn(this.makeMailHost());
  }

  private async mailTeardownWebhook(): Promise<void> {
    await teardownMailboxWebhookFn(this.makeMailHost());
  }

  private async mailScheduleRenewal(expiration: Date): Promise<void> {
    const renewalCallback = await this.callback(this.mailRenewWatch);
    await this.scheduleRecurring(
      "mailbox-watch-renewal",
      renewalCallback,
      getMailboxRenewalSchedule(expiration)
    );
  }

  async mailRenewWatch(): Promise<void> {
    await renewMailboxWatchFn(this.makeMailHost());
  }

  async mailSelfHealCheck(): Promise<void> {
    await selfHealCheckFn(this.makeMailHost());
  }

  private async mailScheduleSelfHeal(): Promise<void> {
    const callback = await this.callback(this.mailSelfHealCheck);
    await this.scheduleRecurring("mailbox-self-heal", callback, {
      intervalMs: SELF_HEAL_INTERVAL_MS,
    });
  }

  private async mailQueueIncrementalSync(): Promise<void> {
    const callback = await this.callback(this.mailIncrementalSyncBatch);
    await this.runTask(callback);
  }

  // --- Mail framework callbacks: webhook + outbound write-back ---------------
  // The runtime dispatches these by their framework names. Each delegates to
  // the extracted Gmail function, which no-ops for non-mail threads (the
  // write-backs gate on meta.threadId, which only Gmail threads carry, and
  // onCreateLink gates on draft.type === "email").

  /** Pub/Sub webhook handler (single mailbox-wide watch → single handler). */
  async onGmailWebhook(
    request: WebhookRequest,
    _channelId?: string
  ): Promise<void> {
    const result = await onGmailWebhookFn(this.makeMailHost(), request);
    if ("done" in result) return;
    await this.mailQueueIncrementalSync();
  }

  async onNoteCreated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    return onNoteCreatedFn(this.makeMailHost(), note, thread);
  }

  async onThreadRead(
    thread: Thread,
    actor: Actor,
    unread: boolean
  ): Promise<void> {
    await onThreadReadFn(this.makeMailHost(), thread, actor, unread);
  }

  async onThreadToDo(
    thread: Thread,
    actor: Actor,
    todo: boolean,
    options: { date?: Date }
  ): Promise<void> {
    await onThreadToDoFn(this.makeMailHost(), thread, actor, todo, options);
  }

  /**
   * Outbound link creation, routed by draft type across products: Tasks owns
   * `task` drafts, Mail owns `email` drafts. Each extracted function also
   * returns null for the other's types, so this routing is belt-and-braces.
   */
  override async onCreateLink(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    if (draft.type === "task") {
      return tasksOnCreateLinkFn(this.makeTasksHost(), draft);
    }
    return onCreateLinkFn(this.makeMailHost(), draft);
  }

  /** Write back link status changes (Tasks owns this; Mail has no onLinkUpdated). */
  async onLinkUpdated(link: Link): Promise<void> {
    await tasksOnLinkUpdatedFn(this.makeTasksHost(), link);
  }

  override async downloadAttachment(ref: string): Promise<
    | { redirectUrl: string }
    | { body: Uint8Array; mimeType: string; fileName?: string }
  > {
    return downloadAttachmentFn(this.makeMailHost(), ref);
  }

  // ===========================================================================
  // Tasks (Google Tasks) — mirrors @plotday/connector-google-tasks. Polling
  // only (no webhooks). Storage keys are namespaced under "tasks:"; scheduling
  // is owned here. The poll task key `poll:<listId>` is NOT prefixed (a
  // per-instance task key the extracted onChannelDisabledFn passes raw to
  // cancelScheduledTask). onCreateLink is routed by draft.type above;
  // onLinkUpdated is Tasks-only.
  // ===========================================================================

  /** Public set proxy so makeTasksHost() can wrap `this` (host needs public). */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _tasksHostSet(key: string, value: any): Promise<void> {
    return this.set(`tasks:${key}`, value);
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _tasksHostGet<T = any>(key: string): Promise<T | null> {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return this.get<any>(`tasks:${key}`);
  }
  _tasksHostClear(key: string): Promise<void> {
    return this.clear(`tasks:${key}`);
  }

  /**
   * Returns a TasksSyncHost that namespaces every storage key under "tasks:"
   * and routes the scheduler section to this connector's own task* methods
   * (which own this.callback / runTask / scheduleRecurring / cancelScheduledTask).
   */
  private makeTasksHost(): TasksSyncHost {
    const self = this;
    return {
      id: self.id,
      set: (key, value) => self._tasksHostSet(key, value),
      get: <T>(key: string) => self._tasksHostGet<T>(key),
      clear: (key) => self._tasksHostClear(key),
      tools: {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        integrations: self.tools.integrations as any,
      },
      scheduler: {
        queueSyncBatch: (listId) => self.tasksQueueSyncBatch(listId),
        queuePeriodicSyncBatch: (listId) =>
          self.tasksQueuePeriodicSyncBatch(listId),
        schedulePeriodicSync: (listId) => self.tasksSchedulePeriodicSync(listId),
        cancelScheduledTask: (key) => self.cancelScheduledTask(key),
      },
    };
  }

  /** Initial backfill + periodic-poll setup for a task list (raw list id). */
  private async onTasksChannelEnabled(
    rawId: string,
    context?: SyncContext
  ): Promise<void> {
    const result = await tasksOnChannelEnabledFn(this.makeTasksHost(), rawId, {
      syncHistoryMin: context?.syncHistoryMin,
      recovering: context?.recovering,
    });
    if ("skip" in result) return;
    await this.tasksQueueSyncBatch(result.start.listId);
    await this.tasksSchedulePeriodicSync(result.start.listId);
  }

  // --- Tasks scheduling (stays on the connector) ----------------------------

  private async tasksQueueSyncBatch(listId: string): Promise<void> {
    const callback = await this.callback(this.tasksSyncBatch, listId);
    await this.runTask(callback);
  }

  private async tasksQueuePeriodicSyncBatch(listId: string): Promise<void> {
    const callback = await this.callback(this.tasksPeriodicSyncBatch, listId);
    await this.runTask(callback);
  }

  private async tasksSchedulePeriodicSync(listId: string): Promise<void> {
    const syncCallback = await this.callback(this.tasksPeriodicSync, listId);
    await this.scheduleRecurring(`poll:${listId}`, syncCallback, {
      intervalMs: POLL_RECURRING_INTERVAL_MS,
      firstRunAt: new Date(Date.now() + POLL_INTERVAL_MS),
    });
  }

  // --- Tasks sync batches (dispatched callbacks — must live on this class) ---

  async tasksSyncBatch(listId: string): Promise<void> {
    const result = await tasksSyncBatchFn(this.makeTasksHost(), listId);
    if ("done" in result) return;
    await this.tasksQueueSyncBatch(result.next.listId);
  }

  async tasksPeriodicSync(listId: string): Promise<void> {
    const start = await tasksPeriodicSyncFn(this.makeTasksHost(), listId);
    if (!start) return;
    await this.tasksQueuePeriodicSyncBatch(listId);
  }

  async tasksPeriodicSyncBatch(listId: string): Promise<void> {
    const result = await tasksPeriodicSyncBatchFn(this.makeTasksHost(), listId);
    if ("done" in result) return;
    if ("next" in result) {
      await this.tasksQueuePeriodicSyncBatch(result.next.listId);
      return;
    }
    await this.tasksSchedulePeriodicSync(result.reschedule.listId);
  }

  // ===========================================================================
  // Contacts (Google Contacts) — mirrors @plotday/connector-google-contacts.
  // A channelless single-channel, read-only contact IMPORT (no webhooks, no
  // recurring poll, no write-backs). Storage keys namespaced under "contacts:".
  // ===========================================================================

  /** Public set proxy so makeContactsHost() can wrap `this` (host needs public). */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _contactsHostSet(key: string, value: any): Promise<void> {
    return this.set(`contacts:${key}`, value);
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _contactsHostGet<T = any>(key: string): Promise<T | null> {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return this.get<any>(`contacts:${key}`);
  }
  _contactsHostClear(key: string): Promise<void> {
    return this.clear(`contacts:${key}`);
  }

  /**
   * Returns a ContactsSyncHost that namespaces every storage key under
   * "contacts:" and routes its single scheduler hook (queueSyncBatch) back to
   * this connector's own method (which owns this.callback / runTask).
   */
  private makeContactsHost(): ContactsSyncHost {
    const self = this;
    return {
      set: (key, value) => self._contactsHostSet(key, value),
      get: <T>(key: string) => self._contactsHostGet<T>(key),
      clear: (key) => self._contactsHostClear(key),
      tools: {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        integrations: self.tools.integrations as any,
      },
      scheduler: {
        queueSyncBatch: (batchNumber, syncableId) =>
          self.contactsQueueSyncBatch(batchNumber, syncableId),
      },
    };
  }

  /** Kicks off the paginated contact import for the (single) contacts channel. */
  private async onContactsChannelEnabled(rawId: string): Promise<void> {
    const start = await contactsOnChannelEnabledFn(
      this.makeContactsHost(),
      rawId
    );
    if (!start) return;
    await this.contactsQueueSyncBatch(1, rawId);
  }

  private async contactsQueueSyncBatch(
    batchNumber: number,
    syncableId: string
  ): Promise<void> {
    const callback = await this.callback(
      this.contactsSyncBatch,
      batchNumber,
      syncableId
    );
    await this.runTask(callback);
  }

  /** One page of the contact import; chaining (next page) is owned by the fn. */
  async contactsSyncBatch(
    batchNumber: number,
    syncableId: string
  ): Promise<void> {
    await contactsSyncBatchFn(this.makeContactsHost(), batchNumber, syncableId);
  }
}

export default Google;
