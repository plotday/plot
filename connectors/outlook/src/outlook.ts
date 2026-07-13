import { Connector } from "@plotday/twister";
import type {
  Actor,
  ActorId,
  CreateLinkDraft,
  NewLinkWithNotes,
  Note,
  NoteWriteBackResult,
  Thread,
  ToolBuilder,
} from "@plotday/twister";
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
import {
  INCREMENTAL_SYNC_COALESCE_MS,
  INCREMENTAL_SYNC_TASK_KEY,
  MAX_INCREMENTAL_MESSAGES_PER_BATCH,
  drainNotifiedMessagesFn,
  migrateLegacyPendingMessagesFn,
  queueIncrementalSyncFn,
  type OutlookMailSyncHost,
  SELF_HEAL_INTERVAL_MS,
  addEnabledChannelFn,
  removeEnabledChannelFn,
  getEnabledChannelsFn,
  ensureMailboxSubscriptionFn,
  setupMailboxSubscriptionFn,
  teardownMailboxSubscriptionFn,
  renewMailboxSubscriptionFn,
  selfHealCheckFn,
  recoverMailboxDeliveryFn,
  requeueInitialSyncFn,
  initialSyncBatchFn,
  incrementalSyncBatchFn,
  onOutlookMailWebhookFn,
  onCreateLinkFn,
  onNoteCreatedFn,
  onThreadReadFn,
  onThreadToDoFn,
  downloadAttachmentFn,
  getMailboxRenewalSchedule,
  type InitialSyncState,
} from "@plotday/connector-outlook-mail";
import {
  type OutlookCalendarSyncHost,
  type WatchState,
  clearBuffersFn as calendarClearBuffersFn,
  extractRSVPParamsFn,
  getApiFn as getCalendarApiFn,
  initOutlookCalendarFn,
  renewOutlookWatchFn,
  scheduleSubscriptionRenewalFn,
  setupOutlookWatchFn,
  startIncrementalSyncFn,
  stopSyncFn,
  syncOutlookBatchFn,
  tryGetApiFn,
  updateEventRSVPWithApiFn,
  watchNeedsReactiveRenewalFn,
} from "@plotday/connector-outlook-calendar";

import { OUTLOOK_SCOPES, PRODUCTS } from "./scopes";
import { composeChannels } from "./compose";
import { parse } from "./product-channel";
import { PRODUCTS_BY_KEY } from "./products/product";

/**
 * Combined Outlook (Microsoft Graph) connector: Mail, Calendar, and Contacts
 * under a single OAuth grant.
 *
 * All products run through one Microsoft account. Channel ids are namespaced
 * `"<product>:<rawId>"` (see {@link parse} / `./product-channel`) so each
 * product's storage and lifecycle stay isolated. Mail and Calendar are handled
 * directly by this class — Mail via a `mail:`-namespaced
 * {@link OutlookMailSyncHost} and Calendar via a `calendar:`-namespaced
 * {@link OutlookCalendarSyncHost} — each wrapping `this` and driving the
 * extracted `@plotday/connector-outlook-mail` /
 * `@plotday/connector-outlook-calendar` sync functions. Contacts is wired in a
 * later phase (F1).
 *
 * **Required OAuth Scopes** (declared as optional scope groups in
 * {@link OUTLOOK_SCOPES}; per-product availability is derived from the granted
 * `token.scopes`):
 * - Mail: `Mail.ReadWrite`, `Mail.Send`
 * - Calendar: `Calendars.ReadWrite`
 * - Contacts: `People.Read`, `Contacts.Read`
 */
export class Outlook extends Connector<Outlook> {
  static readonly handleReplies = true;

  readonly provider = AuthProvider.Microsoft;

  readonly dynamicLinkTypes = true;

  readonly scopes = OUTLOOK_SCOPES;

  /**
   * Per-product metadata for the combined-connection setup/status UX. Each
   * entry's `scopeGroupId` matches an `OptionalScopeGroup.id` in OUTLOOK_SCOPES,
   * so the API can derive per-product enablement from granted scopes +
   * enabled channels.
   */
  readonly products = PRODUCTS;

  readonly channelNoun = { singular: "channel", plural: "channels" };

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://graph.microsoft.com/*"] }),
      files: build(Files),
    };
  }

  /**
   * Records the connecting user's actor id so Mail sync can attribute synced
   * threads to the account owner. Stored under the Mail product's key
   * namespace, matching what the extracted sync reads via its host.
   */
  override async activate(context: {
    auth: Authorization;
    actor: Actor;
  }): Promise<void> {
    await this.makeMailHost().set("auth_actor_id", context.actor.id);
  }

  async getChannels(
    _auth: Authorization | null,
    token: AuthToken | null
  ): Promise<Channel[]> {
    if (!token) return [];
    return composeChannels(Object.values(PRODUCTS_BY_KEY), token);
  }

  /**
   * Durable recovery backstop, run on every deploy. Re-asserts recurring
   * maintenance for a healthy mailbox and re-establishes (plus backfills) a
   * stranded one. See {@link recoverMailboxDeliveryFn}.
   */
  override async upgrade(): Promise<void> {
    // One-time migration of pre-drain pending-message bookkeeping.
    await migrateLegacyPendingMessagesFn(this.makeMailHost());
    await recoverMailboxDeliveryFn(this.makeMailHost());
  }

  async onChannelEnabled(
    channel: Channel,
    context?: SyncContext
  ): Promise<void> {
    const { product: productKey, rawId } = parse(channel.id);

    if (productKey === "mail") {
      await this.onMailChannelEnabled(rawId, context);
      return;
    }

    if (productKey === "calendar") {
      await this.onCalendarChannelEnabled(rawId, context);
      return;
    }

    // Contacts is an intentional no-op: Outlook has no contacts IMPORT.
    // Enabling the synthetic `contacts:contacts` channel only signals the
    // intent to grant the People.Read / Contacts.Read scopes, which Mail's
    // sync reads via `token.scopes` to enrich sender display names
    // (see enrichLinkContactsFromOutlook). There is no sync to start.
    if (productKey === "contacts") {
      return;
    }
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    const { product: productKey, rawId } = parse(channel.id);

    if (productKey === "mail") {
      await this.stopMailSync(rawId);
      return;
    }

    if (productKey === "calendar") {
      await this.stopCalendarSync(rawId);
      return;
    }

    // Contacts no-op (no import to tear down): see onChannelEnabled. Disabling
    // only withdraws scope intent; nothing was started.
    if (productKey === "contacts") {
      return;
    }
  }

  // ===========================================================================
  // Write-back routing (dispatched by the runtime to the acting user's
  // instance). Each delegates to the extracted standalone function via the
  // matching namespaced host:
  //   - compose / notes / read / to-do / attachment download → Mail host
  //   - RSVP (onScheduleContactUpdated) → Calendar host
  // The Mail write-backs no-op for non-mail threads (they gate on
  // meta.conversationId / draft.type === "email"); RSVP no-ops for threads
  // without an Outlook event id. No extra product-enabled guards are needed —
  // routing is by thread/draft shape, matching the standalone connectors and
  // the combined Google connector.
  // ===========================================================================

  /**
   * Outbound link creation from Plot. Only Mail declares a `compose` block
   * (the `email` link type), so route to the Mail host; {@link onCreateLinkFn}
   * returns null for any non-`email` draft type.
   */
  override async onCreateLink(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    return onCreateLinkFn(this.makeMailHost(), draft);
  }

  /** Reply / compose write-back → Mail. */
  async onNoteCreated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    return onNoteCreatedFn(this.makeMailHost(), note, thread);
  }

  /** Read/unread write-back → Mail (mirrors message isRead state). */
  async onThreadRead(
    thread: Thread,
    actor: Actor,
    unread: boolean
  ): Promise<void> {
    await onThreadReadFn(this.makeMailHost(), thread, actor, unread);
  }

  /** To-do / flag write-back → Mail (mirrors message flag state). */
  async onThreadToDo(
    thread: Thread,
    actor: Actor,
    todo: boolean,
    options: { date?: Date }
  ): Promise<void> {
    await onThreadToDoFn(this.makeMailHost(), thread, actor, todo, options);
  }

  /** Attachment download → Mail (resolves the opaque inbound-sync `ref`). */
  override async downloadAttachment(ref: string): Promise<
    | { redirectUrl: string }
    | { body: Uint8Array; mimeType: string; fileName?: string }
  > {
    return downloadAttachmentFn(this.makeMailHost(), ref);
  }

  /**
   * RSVP write-back → Calendar. The dispatch is routed to the RSVPing user's
   * own connector instance (via `twist_instance_for_actor`), so this already
   * runs under that user's auth — no actAs needed. Mirrors
   * OutlookCalendar.onScheduleContactUpdated.
   */
  async onScheduleContactUpdated(
    thread: Thread,
    _scheduleId: string,
    _contactId: ActorId,
    status: ScheduleContactStatus | null,
    actor: Actor
  ): Promise<void> {
    const params = extractRSVPParamsFn(thread, status);
    if (!params) return;

    const { calendarId, eventId, outlookStatus } = params;

    try {
      const api = await getCalendarApiFn(this.makeCalendarHost(), calendarId);
      await updateEventRSVPWithApiFn(
        api,
        calendarId,
        eventId,
        outlookStatus,
        actor.id as ActorId
      );
    } catch (error) {
      console.error("[RSVP Sync] Failed to sync RSVP", {
        event_id: eventId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  // ===========================================================================
  // Mail (Microsoft Graph) — mirrors @plotday/connector-outlook-mail. All
  // storage keys + locks are namespaced under "mail:"; scheduling (callback /
  // runTask / scheduleRecurring / cancelScheduledTask) is owned here and routed
  // back through the host's scheduler boundary.
  // ===========================================================================

  /** Public set proxy so makeMailHost() can wrap `this` (host needs public). */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _mailHostSet(key: string, value: any): Promise<void> {
    return this.set(`mail:${key}`, value);
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _mailHostSetMany(entries: [key: string, value: any][]): Promise<void> {
    return this.setMany(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      entries.map(([key, value]): [string, any] => [`mail:${key}`, value])
    );
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
   * Returns an OutlookMailSyncHost that namespaces every storage key + lock
   * under "mail:" and routes the scheduler section back to this connector's own
   * mail* methods (which own this.callback / runTask / scheduleRecurring /
   * cancelScheduledTask). Durable task keys (mailbox-subscription-renewal,
   * mailbox-self-heal) are NOT prefixed — they're per-instance task keys (one
   * mailbox per connection) and the extracted functions pass those raw keys to
   * cancelScheduledTask.
   */
  private makeMailHost(): OutlookMailSyncHost {
    const self = this;
    return {
      id: self.id,
      set: (key, value) => self._mailHostSet(key, value),
      setMany: (entries) => self._mailHostSetMany(entries),
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
        onOutlookMailWebhook: self.onOutlookMailWebhook,
        setupMailboxSubscription: () => self.mailSetupSubscription(),
        renewMailboxSubscription: () => self.renewMailboxSubscription(),
        scheduleMailboxRenewal: (expiration) =>
          self.mailScheduleRenewal(expiration),
        scheduleSelfHealCheck: () => self.mailScheduleSelfHeal(),
        cancelScheduledTask: (key) => self.cancelScheduledTask(key),
        scheduleDrain: (messageIds) => self.mailScheduleDrain(messageIds),
        queueRenewSubscription: () => self.mailQueueRenewSubscription(),
        requeueInitialSync: (channelId) => self.mailRequeueInitialSync(channelId),
      },
    };
  }

  /**
   * Pre-init for a mail channel (raw Graph folder id): recovery / history-min
   * handling, register the channel, then queue the per-channel initial backfill
   * + the idempotent mailbox-wide subscription setup. Mirrors
   * OutlookMail.onChannelEnabled.
   */
  private async onMailChannelEnabled(
    rawId: string,
    context?: SyncContext
  ): Promise<void> {
    const host = this.makeMailHost();
    const syncHistoryMin = context?.syncHistoryMin;

    if (context?.recovering) {
      // Recovery dispatch after re-auth: drop the per-channel cursors so this
      // channel re-walks its folder and the delta baseline reseeds.
      await host.clear(`initial_state_${rawId}`);
      await host.clear(`delta_${rawId}`);
    } else if (syncHistoryMin) {
      const storedMin = await host.get<string>(`sync_history_min_${rawId}`);
      if (storedMin && new Date(storedMin) <= syncHistoryMin) {
        return;
      }
      await host.set(`sync_history_min_${rawId}`, syncHistoryMin.toISOString());
    }

    await addEnabledChannelFn(host, rawId);

    // observeOnly: auto-observed (a Plot thread was composed into this folder),
    // not explicitly enabled — register the subscription but skip historical
    // backfill.
    if (!context?.observeOnly) {
      const initialState: InitialSyncState = {
        lastSyncTime: syncHistoryMin ?? undefined,
      };
      await host.set(`initial_state_${rawId}`, initialState);
      const initialCallback = await this.callback(
        this.initialSyncBatch,
        rawId,
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

  /** Teardown for a mail channel; mirrors OutlookMail.onChannelDisabled. */
  private async stopMailSync(rawId: string): Promise<void> {
    const host = this.makeMailHost();
    await removeEnabledChannelFn(host, rawId);
    await host.clear(`initial_state_${rawId}`);
    await host.clear(`sync_history_min_${rawId}`);
    await host.clear(`delta_${rawId}`);

    // Tear the mailbox subscription down only if this was the last enabled
    // folder. The next onChannelEnabled rebuilds it.
    const enabled = await getEnabledChannelsFn(host);
    if (enabled.size === 0) {
      await teardownMailboxSubscriptionFn(host);
    }
  }

  // --- Mail dispatched callbacks (must live on this class) -------------------

  /** Per-channel initial backfill; schedules the next batch when more remain. */
  async initialSyncBatch(channelId: string, batchNumber: number): Promise<void> {
    const result = await initialSyncBatchFn(
      this.makeMailHost(),
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

  /** Mailbox-wide incremental sync over a set of notified message ids. */
  async incrementalSyncBatch(messageIds: string[]): Promise<void> {
    await incrementalSyncBatchFn(this.makeMailHost(), messageIds);
  }

  /** Idempotently (re)establish the mailbox subscription + webhook. */
  async ensureMailboxSubscription(): Promise<void> {
    await ensureMailboxSubscriptionFn(this.makeMailHost());
  }

  private async mailSetupSubscription(): Promise<void> {
    await setupMailboxSubscriptionFn(this.makeMailHost());
  }

  private async mailScheduleRenewal(expiration: Date): Promise<void> {
    const renewalCallback = await this.callback(this.renewMailboxSubscription);
    await this.scheduleRecurring(
      "mailbox-subscription-renewal",
      renewalCallback,
      getMailboxRenewalSchedule(expiration)
    );
  }

  async renewMailboxSubscription(): Promise<void> {
    await renewMailboxSubscriptionFn(this.makeMailHost());
  }

  async selfHealCheck(): Promise<void> {
    await selfHealCheckFn(this.makeMailHost());
  }

  private async mailScheduleSelfHeal(): Promise<void> {
    const callback = await this.callback(this.selfHealCheck);
    await this.scheduleRecurring("mailbox-self-heal", callback, {
      intervalMs: SELF_HEAL_INTERVAL_MS,
    });
  }

  /**
   * Record notified message ids and schedule the coalesced drain (mirrors
   * the standalone Outlook Mail connector): the platform's scheduleDrain
   * owns the durable dirty set, coalescing, bounded passes, and per-id
   * retry caps.
   */
  private async mailQueueIncrementalSync(messageIds: string[]): Promise<void> {
    await queueIncrementalSyncFn(this.makeMailHost(), messageIds);
  }

  /** Record ids + schedule the platform drain (host scheduler hook). */
  private async mailScheduleDrain(messageIds: string[]): Promise<void> {
    await this.scheduleDrain(
      INCREMENTAL_SYNC_TASK_KEY,
      this.drainNotifiedMessages,
      {
        ids: messageIds,
        batchSize: MAX_INCREMENTAL_MESSAGES_PER_BATCH,
        delayMs: INCREMENTAL_SYNC_COALESCE_MS,
      }
    );
  }

  /** Drain handler: ingest the notified messages' conversations. */
  async drainNotifiedMessages(
    messageIds: string[]
  ): Promise<{ retry: string[] } | undefined> {
    return drainNotifiedMessagesFn(this.makeMailHost(), messageIds);
  }

  private async mailQueueRenewSubscription(): Promise<void> {
    const callback = await this.callback(this.renewMailboxSubscription);
    await this.runTask(callback);
  }

  /**
   * Re-queue a fresh full backfill of one folder, dropping stale cursors, then
   * schedule the first initial batch. Routed from `host.scheduler` so recovery
   * (run from {@link upgrade}) keeps scheduling on the connector.
   */
  private async mailRequeueInitialSync(channelId: string): Promise<void> {
    const { scheduleInitialBatch } = await requeueInitialSyncFn(
      this.makeMailHost(),
      channelId
    );
    const initial = await this.callback(
      this.initialSyncBatch,
      scheduleInitialBatch.channelId,
      1
    );
    await this.runTask(initial);
  }

  // --- Mail framework callback: webhook -------------------------------------
  // The runtime dispatches this by its framework name. It delegates to the
  // extracted Graph change-notification handler and queues the follow-up tasks
  // the returned descriptor requests.

  /**
   * Graph change-notification handler (synchronous webhook). Echoes the
   * validation handshake, verifies clientState, then queues subscription
   * renewal and/or an incremental sync over the notified message ids.
   */
  async onOutlookMailWebhook(
    request: WebhookRequest
  ): Promise<string | void> {
    const result = await onOutlookMailWebhookFn(this.makeMailHost(), request);
    if ("validationToken" in result) {
      return result.validationToken;
    }
    if ("done" in result) return;
    if (result.queueRenewSubscription) {
      await this.mailQueueRenewSubscription();
    }
    if (result.queueIncrementalSync) {
      await this.mailQueueIncrementalSync(result.messageIds);
    }
  }

  // ===========================================================================
  // Calendar (Microsoft Graph) — mirrors @plotday/connector-outlook-calendar.
  // All storage keys + locks are namespaced under "calendar:"; the calendar
  // sync functions are descriptor-style (no host scheduler block) so scheduling
  // (callback / runTask / scheduleRecurring / cancelScheduledTask) is owned here
  // and acts on the returned descriptors. The watch-renewal task key is prefixed
  // `calendar:watch-renewal:<calendarId>`; the per-calendar id passed to the
  // webhook callback + sync functions is the raw (un-prefixed) calendar id.
  // ===========================================================================

  /**
   * Public set proxy so makeCalendarHost() can wrap `this` through an
   * OutlookCalendarSyncHost interface (which requires public methods).
   */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _calendarHostSet(key: string, value: any): Promise<void> {
    return this.set(`calendar:${key}`, value);
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _calendarHostGet<T = any>(key: string): Promise<T | null> {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return this.get<any>(`calendar:${key}`);
  }
  _calendarHostClear(key: string): Promise<void> {
    return this.clear(`calendar:${key}`);
  }

  /**
   * Returns an OutlookCalendarSyncHost that namespaces every storage key + lock
   * under "calendar:" so calendar state can't collide with mail/contacts keys.
   * The store.list proxy strips the `calendar:` prefix from results so the
   * extracted functions see consistent un-prefixed keys.
   *
   * Descriptor style: no `scheduler` block. The calendar sync functions return
   * descriptors and this class owns the scheduling (see the calendar callback
   * methods below).
   */
  private makeCalendarHost(): OutlookCalendarSyncHost {
    const self = this;
    return {
      set: (key, value) => self._calendarHostSet(key, value),
      get: <T>(key: string) => self._calendarHostGet<T>(key),
      clear: (key) => self._calendarHostClear(key),
      // Read into the MAIL namespace so the calendar sync can check for a
      // `cancel-email:<uid>` marker recorded by the mail sync (Plan B).
      readMailState: (key) => self._mailHostGet(key),
      tools: {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        integrations: self.tools.integrations as any,
        store: {
          acquireLock: (key, ttlMs) =>
            self.tools.store.acquireLock(`calendar:${key}`, ttlMs),
          releaseLock: (key) =>
            self.tools.store.releaseLock(`calendar:${key}`),
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

  /**
   * Pre-init for a calendar channel (raw Graph calendar id): recovery cleanup
   * (stop the stale MS Graph subscription, wipe sync state + buffers) /
   * history-min handling, then queue `initCalendar` as a task. Mirrors
   * OutlookCalendar.onChannelEnabled.
   *
   * Keep this thin: it must return quickly so the HTTP-response boundary
   * doesn't straddle the sync lock. All real init work (lock, webhook setup,
   * sync state, first batch) is deferred to {@link initCalendar}.
   */
  private async onCalendarChannelEnabled(
    rawId: string,
    context?: SyncContext
  ): Promise<void> {
    const host = this.makeCalendarHost();

    if (context?.recovering) {
      // Stop the existing MS Graph subscription BEFORE initCalendar runs.
      // setupOutlookWatch unconditionally creates a fresh subscription and
      // overwrites `outlook_watch_${rawId}`; without this cleanup the old
      // subscription is orphaned on Microsoft's side (firing webhooks until
      // expiry to a connector that no longer recognises them).
      //
      // The pending renewal task needs no explicit cancel here: the durable
      // recurring task keyed `calendar:watch-renewal:${rawId}` that
      // setupOutlookWatch registers via `scheduleRecurring` atomically
      // replaces any pending occurrence for this calendar.
      const oldWatchData = await host.get<WatchState>(
        `outlook_watch_${rawId}`
      );
      if (oldWatchData?.subscriptionId) {
        // tryGetApi handles the token-missing case cleanly — recovery is
        // precisely the path where a stale or invalid token is plausible, so
        // don't throw if the auth state isn't usable.
        const api = await tryGetApiFn(
          host,
          rawId,
          "onCalendarChannelEnabled (recovery cleanup)"
        );
        if (api) {
          try {
            await api.deleteSubscription(oldWatchData.subscriptionId);
          } catch (error) {
            console.warn(
              "Failed to delete stale Outlook subscription on recovery:",
              error instanceof Error ? error.message : error
            );
          }
        }
        await host.clear(`outlook_watch_${rawId}`);
      }

      // Wipe persisted sync state (including the Graph delta token in
      // `state.state`) so the next pass re-walks history. Release any
      // TTL-stuck lock from the pre-recovery outage so initCalendar can
      // acquire fresh.
      await host.clear(`outlook_sync_state_${rawId}`);
      await host.tools.store.releaseLock(`sync_${rawId}`);

      // Clear any `pending_occ:` / `seen_master:` markers left behind by a
      // crashed pre-recovery sync.
      await calendarClearBuffersFn(host, rawId);
    } else if (context?.syncHistoryMin) {
      // Store sync_history_min if provided and not already stored with an
      // equal/earlier value. Skipped on recovery so the recovery pass
      // re-walks even when the window hasn't widened.
      const key = `sync_history_min_${rawId}`;
      const stored = await host.get<string>(key);
      if (stored && new Date(stored) <= context.syncHistoryMin) {
        return; // Already synced with equal or earlier history min
      }
      await host.set(key, context.syncHistoryMin.toISOString());
    }

    await host.set(`sync_enabled_${rawId}`, true);

    // Queue all initialization as a task to avoid blocking the HTTP response.
    const initCallback = await this.callback(this.initCalendar, rawId);
    await this.runTask(initCallback);
  }

  /**
   * Initializes an Outlook calendar channel: acquires the sync lock, sets up
   * the webhook subscription, initializes sync state, and queues the first
   * sync batch. Runs as a queued task so lock acquisition doesn't straddle the
   * HTTP-response boundary. Delegates to {@link initOutlookCalendarFn}; watch
   * setup stays here because it requires `this.callback(this.onOutlookWebhook)`.
   */
  async initCalendar(calendarId: string): Promise<void> {
    const result = await initOutlookCalendarFn(
      this.makeCalendarHost(),
      calendarId
    );
    if ("done" in result) return;

    // Set up the push webhook for this calendar.
    await this.setupOutlookWatch(calendarId);

    const { batchNumber, initialSync } = result.next;
    const syncCallback = await this.callback(
      this.syncOutlookBatch,
      calendarId,
      initialSync,
      batchNumber
    );
    await this.runTask(syncCallback);
  }

  /**
   * Processes one batch of calendar events and schedules the next batch (or the
   * quick→full phase transition, which the descriptor surfaces as another
   * `next`). Delegates to {@link syncOutlookBatchFn} with the `calendar:`
   * namespaced host.
   */
  async syncOutlookBatch(
    calendarId: string,
    initialSync: boolean,
    batchNumber: number = 1
  ): Promise<void> {
    const result = await syncOutlookBatchFn(
      this.makeCalendarHost(),
      calendarId,
      initialSync,
      batchNumber
    );
    if ("done" in result) return;

    const syncCallback = await this.callback(
      this.syncOutlookBatch,
      result.next.calendarId,
      result.next.initialSync,
      result.next.batchNumber
    );
    await this.runTask(syncCallback);
  }

  /**
   * Teardown for a calendar channel: cancels the renewal task, stops the MS
   * Graph subscription, clears sync state + buffers, and drops the enabled
   * flag. Mirrors OutlookCalendar.onChannelDisabled + stopSync.
   */
  private async stopCalendarSync(calendarId: string): Promise<void> {
    // 1. Cancel the scheduled renewal task for this calendar.
    await this.cancelScheduledTask(`calendar:watch-renewal:${calendarId}`);

    // 2. Stop webhook subscription, clear sync state, release lock, and clear
    //    leftover `pending_occ:` / `seen_master:` markers.
    await stopSyncFn(this.makeCalendarHost(), calendarId);

    // 3. Drop the enabled flag.
    await this.makeCalendarHost().clear(`sync_enabled_${calendarId}`);
  }

  // --- Calendar watch / webhook (dispatched callbacks — must live here) ------

  /**
   * Registers the MS Graph subscription (push-notification watch) for the
   * given calendar. The webhook URL embeds a reference to onOutlookWebhook so
   * the runtime routes incoming notifications directly to that method.
   * Idempotent; schedules proactive renewal after success.
   */
  async setupOutlookWatch(calendarId: string): Promise<void> {
    // Microsoft Graph validates subscription endpoints by POSTing with a
    // `validationToken` query parameter and expects the token echoed back as
    // `text/plain`. That requires a synchronous response path — the async
    // (queued) default would just reply `200 { queued: true }` and
    // subscription creation would fail. Opt out explicitly.
    const webhookUrl = await this.tools.network.createWebhook(
      { async: false },
      this.onOutlookWebhook,
      calendarId
    );

    const result = await setupOutlookWatchFn(
      this.makeCalendarHost(),
      webhookUrl,
      calendarId
    );
    if ("skipped" in result) return;

    // Schedule proactive renewal 24h before expiry. MS Graph caps
    // subscriptions at ~3 days; without renewal the webhook silently dies
    // after 72 hours.
    await this.scheduleSubscriptionRenewal(calendarId);
  }

  /**
   * Schedules a durable recurring renewal for the calendar watch. If the
   * renewal window has already passed, renews immediately.
   *
   * @private
   */
  private async scheduleSubscriptionRenewal(calendarId: string): Promise<void> {
    const schedule = await scheduleSubscriptionRenewalFn(
      this.makeCalendarHost(),
      calendarId
    );
    if (!schedule) return;

    if ("immediate" in schedule) {
      // Already past the renewal window — renew now.
      await this.renewOutlookWatch(calendarId);
      return;
    }

    const renewalCallback = await this.callback(
      this.renewOutlookWatch,
      calendarId
    );
    // Singleton durable recurring task: re-scheduling under this key
    // atomically replaces any pending renewal, so renewal chains can never
    // accumulate — even if setupOutlookWatch runs again (re-dispatch,
    // re-init). Keyed `calendar:watch-renewal:<id>` so cancelScheduledTask in
    // stopCalendarSync tears down the right task.
    await this.scheduleRecurring(
      `calendar:watch-renewal:${calendarId}`,
      renewalCallback,
      schedule
    );
  }

  /**
   * Renews an Outlook subscription. Called proactively (scheduled task) or
   * reactively (on webhook near expiry). The descriptor selects the follow-up:
   * `renewed` → schedule the next renewal; `recreate` → re-run setupOutlookWatch
   * (which recreates the subscription AND reschedules renewal); `done` → no-op.
   */
  async renewOutlookWatch(calendarId: string): Promise<void> {
    const result = await renewOutlookWatchFn(
      this.makeCalendarHost(),
      calendarId
    );
    if ("renewed" in result) {
      await this.scheduleSubscriptionRenewal(calendarId);
    } else if ("recreate" in result) {
      await this.setupOutlookWatch(calendarId);
    }
  }

  /**
   * Receives MS Graph push notifications for a specific calendar. Echoes the
   * validation handshake, fires a best-effort reactive renewal when near
   * expiry, then enqueues an incremental sync per change notification.
   *
   * The webhook URL was registered by {@link setupOutlookWatch} with
   * `calendarId` as the extra arg, so the runtime calls this with the right id.
   */
  async onOutlookWebhook(
    request: WebhookRequest,
    calendarId: string
  ): Promise<string | void> {
    if (request.params?.validationToken) {
      // Microsoft Graph subscription validation — echo the token back as
      // text/plain. Plot's sync webhook route maps a string return value to a
      // `text/plain` response automatically.
      return request.params.validationToken;
    }

    const body = request.body;
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      console.warn("Invalid webhook body format");
      return;
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const notifications = (body as { value?: any[] }).value;
    if (!notifications?.length) {
      console.warn("No notifications in webhook body");
      return;
    }

    // Reactive subscription-renewal check: if expiry is <24h away, fire a
    // best-effort renewal alongside the incremental sync. Belt-and-braces with
    // the scheduled renewal task.
    if (await watchNeedsReactiveRenewalFn(this.makeCalendarHost(), calendarId)) {
      this.renewOutlookWatch(calendarId).catch((error) => {
        console.error(
          `Failed to reactively renew Outlook subscription for ${calendarId}:`,
          error
        );
      });
    }

    for (const notification of notifications) {
      if (notification.changeType) {
        await this.startIncrementalSync(calendarId);
      }
    }
  }

  /**
   * Acquires the sync lock and enqueues an incremental sync batch for the given
   * calendar. No-op when the lock is already held (another sync in progress).
   */
  private async startIncrementalSync(calendarId: string): Promise<void> {
    const result = await startIncrementalSyncFn(
      this.makeCalendarHost(),
      calendarId
    );
    if ("done" in result) return;

    const { batchNumber, initialSync } = result.next;
    const callback = await this.callback(
      this.syncOutlookBatch,
      calendarId,
      initialSync,
      batchNumber
    );
    await this.runTask(callback);
  }
}

export default Outlook;
