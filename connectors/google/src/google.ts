import GoogleContacts from "@plotday/connector-google-contacts";
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
import { Connector } from "@plotday/twister";
import type { Actor, ActorId, Thread, ToolBuilder } from "@plotday/twister";
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
        urls: ["https://www.googleapis.com/calendar/*"],
      }),
      googleContacts: build(GoogleContacts),
    };
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
}

export default Google;
