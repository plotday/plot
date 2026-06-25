import {
  type Actor,
  type ActorId,
  Connector,
  type Thread,
  type ToolBuilder,
} from "@plotday/twister";
import type { ScheduleContactStatus } from "@plotday/twister/schedule";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";

import {
  type Calendar,
  OUTLOOK_CALENDAR_LINK_TYPES,
  OUTLOOK_CALENDAR_SCOPE,
  getOutlookCalendarChannels,
} from "./channels";
import {
  type OutlookCalendarSyncHost,
  type WatchState,
  clearBuffersFn,
  extractRSVPParamsFn,
  getApiFn,
  getCalendarsFn,
  initOutlookCalendarFn,
  renewOutlookWatchFn,
  scheduleSubscriptionRenewalFn,
  setupOutlookWatchFn,
  startIncrementalSyncFn,
  startSyncFn,
  stopSyncFn,
  syncOutlookBatchFn,
  tryGetApiFn,
  updateEventRSVPWithApiFn,
  watchNeedsReactiveRenewalFn,
} from "./sync";

type SyncOptions = {
  timeMin?: Date | null;
  timeMax?: Date | null;
};

/**
 * Microsoft Outlook Calendar integration tool.
 *
 * Provides integration with Microsoft Outlook Calendar and Exchange Online,
 * supporting event synchronization, webhook notifications, and Microsoft
 * Graph API compatibility.
 *
 * **Features:**
 * - OAuth 2.0 authentication with Microsoft
 * - Real-time event synchronization via Microsoft Graph
 * - Webhook-based change notifications
 * - Support for recurring events and exceptions
 * - Exchange Online and Outlook.com compatibility
 * - Batch processing for large calendars
 *
 * **Required OAuth Scopes:**
 * - `https://graph.microsoft.com/calendars.readwrite` - Read/write calendar access
 *
 * @example
 * ```typescript
 * class CalendarSyncTwist extends Twist {
 *   build(build: ToolBuilder) {
 *     return {
 *       outlookCalendar: build(OutlookCalendar),
 *       plot: build(Plot, { thread: { access: ThreadAccess.Create } }),
 *     };
 *   }
 *
 *   // Auth and calendar selection handled in the twist edit modal.
 *   // Events are delivered via the startSync callback.
 * }
 * ```
 */
export class OutlookCalendar extends Connector<OutlookCalendar> {
  static readonly PROVIDER = AuthProvider.Microsoft;
  static readonly SCOPES = [OUTLOOK_CALENDAR_SCOPE];

  readonly provider = AuthProvider.Microsoft;
  readonly channelNoun = { singular: "calendar", plural: "calendars" };
  readonly autoEnableNewChannelsByDefault = true;
  readonly scopes = OutlookCalendar.SCOPES;
  readonly access = [
    "Reads your events to add them to your agenda",
    "Writes your event RSVPs",
  ];
  readonly linkTypes = OUTLOOK_CALENDAR_LINK_TYPES;

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://graph.microsoft.com/*"] }),
    };
  }

  // ---------------------------------------------------------------------------
  // Host wrapper + private helper delegators
  //
  // The Connector base class exposes set/get/clear as `protected`, but
  // OutlookCalendarSyncHost requires them as public. We bridge this via a host
  // object that delegates through public wrapper methods below.
  // ---------------------------------------------------------------------------

  /** Public set wrapper so the host object can expose it. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _hostSet(key: string, value: any): Promise<void> {
    return this.set(key, value);
  }
  /** Public get wrapper so the host object can expose it. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _hostGet<T = any>(key: string): Promise<T | null> {
    return this.get<any>(key);
  }
  /** Public clear wrapper so the host object can expose it. */
  _hostClear(key: string): Promise<void> {
    return this.clear(key);
  }

  /**
   * Returns an OutlookCalendarSyncHost backed by this connector instance.
   * Passes through all tool access and exposes set/get/clear as public members.
   */
  private host(): OutlookCalendarSyncHost {
    const self = this;
    return {
      set: (key, value) => self._hostSet(key, value),
      get: <T>(key: string) => self._hostGet<T>(key),
      clear: (key) => self._hostClear(key),
      tools: {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        integrations: self.tools.integrations as any,
        store: {
          acquireLock: (key, ttlMs) =>
            self.tools.store.acquireLock(key, ttlMs),
          releaseLock: (key) => self.tools.store.releaseLock(key),
          list: (prefix) => self.tools.store.list(prefix),
        },
      },
    };
  }

  /**
   * Returns available Outlook calendars as channel resources.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    return getOutlookCalendarChannels(token);
  }

  /**
   * Called when a channel calendar is enabled for syncing.
   * Auto-starts sync for the calendar.
   *
   * Three cases (see SyncContext docs):
   *  - Initial enable: full backfill from scratch.
   *  - Already-enabled history-min refresh: skips when stored window is
   *    already at least as wide.
   *  - Recovery (`context.recovering = true`): the user re-authorized a
   *    previously-broken connection. Drop the persisted delta token and
   *    sync lock so the next pass re-walks history and picks up events
   *    that changed during the auth gap.
   *
   * Keep this method thin: it must return quickly so the HTTP response
   * boundary doesn't hold the sync lock. All real init work (lock,
   * webhook setup, sync state, first batch) is deferred to initCalendar
   * which runs inside a queued task.
   */
  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    if (context?.recovering) {
      // Stop the existing MS Graph subscription BEFORE initCalendar runs.
      // setupOutlookWatch unconditionally creates a fresh subscription and
      // overwrites `outlook_watch_${calendarId}`; without this cleanup the
      // old subscription is orphaned on Microsoft's side (firing webhooks
      // until expiry to a connector that no longer recognises them).
      //
      // The pending renewal task needs no explicit cancel here: the
      // durable recurring task keyed `watch-renewal:${calendarId}` that
      // setupOutlookWatch registers via `scheduleRecurring` atomically
      // replaces any pending occurrence for this calendar, so a stale
      // chain can't accumulate.
      const oldWatchData = await this.get<WatchState>(
        `outlook_watch_${channel.id}`
      );
      if (oldWatchData?.subscriptionId) {
        // tryGetApi handles the token-missing case cleanly — recovery
        // is precisely the path where a stale or invalid token is
        // plausible, so don't throw if the auth state isn't usable.
        const api = await tryGetApiFn(
          this.host(),
          channel.id,
          "onChannelEnabled (recovery cleanup)"
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
        await this.clear(`outlook_watch_${channel.id}`);
      }

      // Wipe persisted sync state (including the Graph delta token in
      // `state.state`) so the next pass re-walks history. Clearing is
      // idempotent and cheap. Release any TTL-stuck lock from the
      // pre-recovery outage so initCalendar can acquire fresh.
      await this.clear(`outlook_sync_state_${channel.id}`);
      await this.tools.store.releaseLock(`sync_${channel.id}`);

      // Clear any `pending_occ:` / `seen_master:` markers left behind by
      // the crashed pre-recovery sync. Stale markers from a half-done
      // run can otherwise cause the next full-pass orphan flush to
      // materialise empty Untitled threads (leftover `pending_occ`
      // matching leftover `seen_master` whose link no longer exists).
      await clearBuffersFn(this.host(), channel.id);
    } else if (context?.syncHistoryMin) {
      // Store sync_history_min if provided and not already stored with
      // an equal/earlier value. Skipped on recovery so the recovery pass
      // re-walks even when the window hasn't widened.
      const key = `sync_history_min_${channel.id}`;
      const stored = await this.get<string>(key);
      if (stored && new Date(stored) <= context.syncHistoryMin) {
        return; // Already synced with equal or earlier history min
      }
      await this.set(key, context.syncHistoryMin.toISOString());
    }

    await this.set(`sync_enabled_${channel.id}`, true);

    // Queue all initialization as a task to avoid blocking the HTTP
    // response. initCalendar acquires the sync lock, sets up the webhook,
    // initializes sync state, and starts the first batch.
    const initCallback = await this.callback(this.initCalendar, channel.id);
    await this.runTask(initCallback);
  }

  /**
   * Initializes an Outlook calendar channel: acquires the sync lock, sets
   * up the webhook subscription, initializes sync state, and queues the
   * first sync batch. Runs as a queued task so the lock acquisition
   * doesn't straddle the HTTP-response boundary (where a dropped task
   * could leave the lock held until the TTL expires).
   *
   * Delegates token check, lock acquisition, and initial SyncState setup
   * to {@link initOutlookCalendarFn}. Watch setup stays here because it
   * requires `this.callback(this.onOutlookWebhook, ...)`.
   */
  async initCalendar(calendarId: string): Promise<void> {
    const result = await initOutlookCalendarFn(this.host(), calendarId);
    if ("done" in result) return;

    // Setup webhook for this calendar
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
   * Called when a channel calendar is disabled.
   * Stops sync and archives threads from this channel.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
    await this.clear(`sync_enabled_${channel.id}`);
  }

  async getCalendars(calendarId: string): Promise<Calendar[]> {
    return getCalendarsFn(this.host(), calendarId);
  }

  async startSync(
    options: {
      calendarId: string;
    } & SyncOptions,
  ): Promise<void> {
    const { calendarId } = options;

    const result = await startSyncFn(this.host(), options);
    if ("done" in result) return;

    // Setup webhook for this calendar
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

  async stopSync(calendarId: string): Promise<void> {
    // 1. Cancel the scheduled renewal task for this calendar.
    await this.cancelScheduledTask(`watch-renewal:${calendarId}`);

    // 2. Stop webhook subscription, clear sync state, release lock, and
    //    clear leftover `pending_occ:` / `seen_master:` markers.
    await stopSyncFn(this.host(), calendarId);
  }

  /**
   * Schedule proactive renewal of an Outlook subscription 24 hours before
   * expiry. MS Graph caps calendar subscriptions at ~3 days, so without
   * renewal every connection's webhook silently dies after 72 hours.
   *
   * @private
   */
  private async scheduleSubscriptionRenewal(calendarId: string): Promise<void> {
    const schedule = await scheduleSubscriptionRenewalFn(
      this.host(),
      calendarId
    );
    if (!schedule) return;

    if ("immediate" in schedule) {
      // Already past the renewal window — renew now.
      await this.renewOutlookWatch(calendarId);
      return;
    }

    // Create callback for renewal (only pass calendarId - serializable!)
    const renewalCallback = await this.callback(
      this.renewOutlookWatch,
      calendarId
    );

    // Singleton scheduled task: re-scheduling under this key atomically
    // replaces any pending renewal, so renewal chains can never accumulate —
    // even if setupOutlookWatch runs again (re-dispatch, re-init).
    await this.scheduleRecurring(
      `watch-renewal:${calendarId}`,
      renewalCallback,
      schedule
    );
  }

  /**
   * Renew an Outlook subscription by extending its expiry via PATCH.
   * Called either proactively (scheduled task) or reactively (on webhook).
   * Gracefully handles errors without throwing.
   *
   * @private
   */
  async renewOutlookWatch(calendarId: string): Promise<void> {
    const result = await renewOutlookWatchFn(this.host(), calendarId);
    if ("renewed" in result) {
      // Schedule the next renewal 24h before the new expiry.
      await this.scheduleSubscriptionRenewal(calendarId);
    } else if ("recreate" in result) {
      // Fallback: delete + recreate. setupOutlookWatch reschedules the
      // next renewal task at the end.
      await this.setupOutlookWatch(calendarId);
    }
  }

  async setupOutlookWatch(calendarId: string): Promise<void> {
    // Microsoft Graph validates subscription endpoints by POSTing with a
    // `validationToken` query parameter and expects the token echoed back
    // as `text/plain`. That requires a synchronous response path — the
    // async (queued) default would just reply `200 { queued: true }` and
    // subscription creation would fail. Opt out explicitly.
    const webhookUrl = await this.tools.network.createWebhook(
      { async: false },
      this.onOutlookWebhook,
      calendarId
    );

    const result = await setupOutlookWatchFn(
      this.host(),
      webhookUrl,
      calendarId
    );
    if ("skipped" in result) return;

    // Schedule proactive renewal 24 hours before expiry. MS Graph caps
    // subscriptions at ~3 days; without renewal the webhook silently
    // dies after 72 hours.
    await this.scheduleSubscriptionRenewal(calendarId);
  }

  async syncOutlookBatch(
    calendarId: string,
    initialSync: boolean,
    batchNumber: number = 1
  ): Promise<void> {
    const result = await syncOutlookBatchFn(
      this.host(),
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

  async onOutlookWebhook(
    request: WebhookRequest,
    calendarId: string
  ): Promise<string | void> {
    if (request.params?.validationToken) {
      // Microsoft Graph subscription validation — echo the token back as
      // text/plain. Plot's sync webhook route maps a string return value
      // to a `text/plain` response automatically.
      return request.params.validationToken;
    }

    const body = request.body;
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      console.warn("Invalid webhook body format");
      return;
    }

    const notifications = (body as { value?: any[] }).value;
    if (!notifications?.length) {
      console.warn("No notifications in webhook body");
      return;
    }

    // Reactive subscription-renewal check: if expiry is <24h away, fire a
    // best-effort renewal alongside the incremental sync. Belt-and-braces
    // with the scheduled renewal task.
    if (await watchNeedsReactiveRenewalFn(this.host(), calendarId)) {
      this.renewOutlookWatch(calendarId).catch((error) => {
        console.error(
          `Failed to reactively renew Outlook subscription for ${calendarId}:`,
          error
        );
      });
    }

    for (const notification of notifications) {
      if (notification.changeType) {
        // Trigger incremental sync
        await this.startIncrementalSync(calendarId);
      }
    }
  }

  private async startIncrementalSync(calendarId: string): Promise<void> {
    const result = await startIncrementalSyncFn(this.host(), calendarId);
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

  /**
   * Called when a user changes their RSVP status in Plot. The dispatch is
   * routed (via `twist_instance_for_actor` in `twist_instance_schedule_contact`)
   * to the RSVPing user's own connector instance, so this method already runs
   * under that user's auth — no actAs needed.
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
      const api = await getApiFn(this.host(), calendarId);
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
}

export default OutlookCalendar;
