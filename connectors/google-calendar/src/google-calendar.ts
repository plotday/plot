import GoogleContacts from "@plotday/connector-google-contacts";
import {
  type Actor,
  type ActorId,
  Connector,
  type Link,
  type Thread,
  type ToolBuilder,
} from "@plotday/twister";
import type { ScheduleContactStatus } from "@plotday/twister/schedule";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";

import { GoogleApi, type SyncState } from "./google-api";
import {
  CALENDAR_EVENTS_SCOPE,
  CALENDAR_LIST_SCOPE,
  CALENDAR_LINK_TYPES,
  type Calendar,
  getCalendarChannels,
} from "./channels";
import {
  SYNC_LOCK_TTL_MS,
  cancelEventWithApiFn,
  clearBuffersFn,
  extractRSVPParamsFn,
  getApiFn,
  getWatchRenewalScheduleFn,
  resolveCalendarIdFn,
  runCalendarInit,
  runSyncBatch,
  setupCalendarWatchFn,
  startIncrementalSyncFn,
  stopCalendarWatchFn,
  updateEventRSVPWithApiFn,
  validateCalendarWebhookFn,
} from "./sync";

type SyncOptions = {
  timeMin?: Date | null;
  timeMax?: Date | null;
};

/**
 * Google Calendar integration tool.
 *
 * Provides seamless integration with Google Calendar, supporting event
 * synchronization, real-time updates via webhooks, and comprehensive
 * recurrence pattern handling.
 *
 * **Features:**
 * - OAuth 2.0 authentication with Google
 * - Real-time event synchronization
 * - Webhook-based change notifications
 * - Support for recurring events and exceptions
 * - Batch processing for large calendars
 * - Automatic retry on failures
 *
 * **Required OAuth Scopes:**
 * - `https://www.googleapis.com/auth/calendar.calendarlist.readonly` - Read calendar list
 * - `https://www.googleapis.com/auth/calendar.events` - Read/write calendar events
 *
 * @example
 * ```typescript
 * class CalendarSyncTwist extends Twist {
 *   private googleCalendar: GoogleCalendar;
 *
 *   constructor(id: string, tools: Tools) {
 *     super();
 *     this.googleCalendar = tools.get(GoogleCalendar);
 *   }
 *
 *   async activate() {
 *     const authLink = await this.googleCalendar.requestAuth("onGoogleAuth", {
 *       provider: "google"
 *     });
 *
 *     await this.plot.createThread({
 *       title: "Connect Google Calendar",
 *     });
 *   }
 *
 *   async onGoogleAuth(auth: CalendarAuth, context: any) {
 *     const calendars = await this.googleCalendar.getCalendars(auth.authToken);
 *
 *     // Start syncing primary calendar
 *     const primary = calendars.find(c => c.primary);
 *     if (primary) {
 *       await this.googleCalendar.startSync(
 *         auth.authToken,
 *         primary.id,
 *         "onCalendarEvent",
 *         {
 *           options: {
 *             timeMin: new Date(), // Only sync future events
 *           }
 *         }
 *       );
 *     }
 *   }
 *
 *   async onCalendarEvent(thread: NewThreadWithNotes, context: any) {
 *     // Process Google Calendar events
 *     await this.plot.createThread(thread);
 *   }
 * }
 * ```
 */
export class GoogleCalendar extends Connector<GoogleCalendar> {
  static readonly PROVIDER = AuthProvider.Google;
  static readonly EVENTS_SCOPE = CALENDAR_EVENTS_SCOPE;
  static readonly CALENDAR_LIST_SCOPE = CALENDAR_LIST_SCOPE;

  readonly provider = AuthProvider.Google;
  readonly channelNoun = { singular: "calendar", plural: "calendars" };
  readonly scopes = {
    required: [GoogleCalendar.EVENTS_SCOPE],
    optional: [
      {
        id: "contacts",
        label: "Add names to events using contacts",
        scopes: GoogleContacts.SCOPES,
        default: true,
      },
      {
        id: "calendars",
        label: "List all calendars",
        description:
          "List all calendars so you can choose which to sync. If disabled, only your primary calendar will be synced.",
        scopes: [GoogleCalendar.CALENDAR_LIST_SCOPE],
        default: true,
      },
    ],
  };
  readonly access = [
    "Reads your events to add them to your agenda",
    "Writes your event RSVPs",
  ];
  readonly linkTypes = CALENDAR_LINK_TYPES;

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: ["https://www.googleapis.com/calendar/*"],
      }),
      googleContacts: build(GoogleContacts),
    };
  }

  async upgrade(): Promise<void> {
    // Old boolean sync_lock_* keys are obsolete (Store.acquireLock manages
    // its own namespace). Clean them up so they don't shadow anything.
    const keys = await this.tools.store.list("sync_lock_");
    for (const key of keys) {
      await this.clear(key);
    }

    // Re-assert durable watch-renewal chains for all watched calendars so that
    // any dead chains (e.g. from a missed beat before this migration) are
    // resurrected on deploy. scheduleWatchRenewal is idempotent — re-scheduling
    // under the same key atomically replaces any pending task.
    const watchKeys = await this.tools.store.list("calendar_watch_");
    for (const key of watchKeys) {
      const calendarId = key.slice("calendar_watch_".length);
      await this.scheduleWatchRenewal(calendarId);
    }
  }

  /**
   * Returns available calendars as channel resources after authorization.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    return getCalendarChannels(token);
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
   *    previously-broken connection. Drop the persisted sync token and
   *    sync lock so the next pass re-walks history and picks up events
   *    that changed during the auth gap (Google invalidates syncTokens
   *    after ~7 days, so the prior cursor is likely useless anyway).
   */
  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    const resolvedCalendarId = await this.resolveCalendarId(channel.id);
    if (context?.recovering) {
      // Wipe incremental cursor + sync state so initCalendar re-walks
      // history. The lock is owned by the framework now and self-expires;
      // we don't touch it here.
      await this.clear(`last_sync_token_${resolvedCalendarId}`);
      await this.clear(`last_sync_token_${channel.id}`);
      await this.clear(`sync_state_${resolvedCalendarId}`);
      await this.tools.store.releaseLock(`sync_${resolvedCalendarId}`);

      // Clear any `pending_occ:` and `seen_master:` markers left over
      // from the crashed pre-recovery sync. Stale markers from a half-
      // done run can otherwise cause the next full-pass orphan flush
      // to materialise empty Untitled threads (leftover `pending_occ`
      // matching leftover `seen_master` whose actual link no longer
      // exists in the DB).
      await this.clearBuffers(resolvedCalendarId);
    } else if (context?.syncHistoryMin) {
      // Store sync_history_min if provided and not already stored with an
      // equal/earlier value. Skipped on recovery so the recovery pass
      // re-walks even when the window hasn't widened.
      const key = `sync_history_min_${channel.id}`;
      const stored = await this.get<string>(key);
      if (stored && new Date(stored) <= context.syncHistoryMin) {
        return; // Already synced with equal or earlier history min
      }
      await this.set(key, context.syncHistoryMin.toISOString());
    }

    // Queue all initialization as a task to avoid blocking the HTTP response.
    // initCalendar resolves the calendar ID, sets up the webhook, and starts sync.
    const initCallback = await this.callback(this.initCalendar, channel.id);
    await this.runTask(initCallback);
  }

  /**
   * Initializes a calendar channel: resolves the calendar ID, sets up the webhook,
   * and starts the initial sync. Runs as a task to avoid blocking the HTTP response.
   *
   * Delegates token check, ID resolution, lock acquisition, and initial SyncState
   * setup to {@link runCalendarInit}. Watch setup stays here because it requires
   * `this.callback(this.onCalendarWebhook, ...)`.
   */
  async initCalendar(calendarId: string): Promise<void> {
    const result = await runCalendarInit(this.makeHost(), calendarId);
    if ("done" in result) return;

    const { resolvedCalendarId, batchNumber, mode, initialSync } = result.next;

    // Set up the push webhook for this calendar. The watch only powers live
    // incremental updates — it is NOT required for the initial backfill, and
    // periodic sync still picks up changes without it. A watch failure (e.g.
    // a transient Google API error, or an environment without an HTTPS
    // webhook endpoint) must therefore never abort sync setup before the
    // sync batch below is queued, or the calendar would never populate.
    try {
      await this.setupCalendarWatch(resolvedCalendarId);
    } catch (error) {
      console.error(
        `Failed to set up calendar watch for ${resolvedCalendarId}; continuing with sync (live updates disabled until next renewal):`,
        error
      );
    }

    const syncCallback = await this.callback(
      this.syncBatch,
      batchNumber,
      mode,
      resolvedCalendarId,
      initialSync
    );
    await this.runTask(syncCallback);
  }

  /**
   * Called when a channel calendar is disabled.
   * Stops sync and archives threads from this channel.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
  }

  // ---------------------------------------------------------------------------
  // Host wrapper + private helper delegators
  //
  // The Connector base class exposes set/get/clear as `protected`, but
  // CalendarSyncHost requires them as public. We bridge this via a host
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
   * Returns a CalendarSyncHost backed by this connector instance.
   * Passes through all tool access and exposes set/get/clear as public members.
   */
  private makeHost(): import("./sync").CalendarSyncHost {
    const self = this;
    return {
      set: (key, value) => self._hostSet(key, value),
      get: <T>(key: string) => self._hostGet<T>(key),
      clear: (key) => self._hostClear(key),
      tools: {
        integrations: self.tools.integrations as any,
        googleContacts: self.tools.googleContacts,
        store: {
          acquireLock: (key, ttlMs) =>
            self.tools.store.acquireLock(key, ttlMs),
          releaseLock: (key) => self.tools.store.releaseLock(key),
          list: (prefix) => self.tools.store.list(prefix),
        },
      },
    };
  }

  private async getApi(calendarId: string): Promise<GoogleApi> {
    return getApiFn(this.makeHost(), calendarId);
  }

  /**
   * Resolves "primary" calendar ID to the actual calendar ID (user's email).
   * Returns the calendarId unchanged if it's not "primary".
   */
  private async resolveCalendarId(calendarId: string): Promise<string> {
    return resolveCalendarIdFn(this.makeHost(), calendarId);
  }

  async getCalendars(authToken: string): Promise<Calendar[]> {
    const api = await this.getApi(authToken);
    const data = (await api.call(
      "GET",
      "https://www.googleapis.com/calendar/v3/users/me/calendarList"
    )) as {
      items: Array<{
        id: string;
        summary: string;
        description?: string;
        primary?: boolean;
        accessRole?: string;
      }>;
    };

    return data.items.map((item) => ({
      id: item.id,
      name: item.summary,
      description: item.description || null,
      primary: item.primary || false,
      accessRole: item.accessRole ?? null,
    }));
  }

  async startSync(
    options: {
      calendarId: string;
    } & SyncOptions
  ): Promise<void> {
    const { calendarId, timeMin, timeMax } = options;

    // Resolve "primary" to actual calendar ID to ensure consistent storage keys
    const resolvedCalendarId = await this.resolveCalendarId(calendarId);

    const acquired = await this.tools.store.acquireLock(
      `sync_${resolvedCalendarId}`,
      SYNC_LOCK_TTL_MS
    );
    if (!acquired) {
      return;
    }

    // Set up the push webhook for this calendar. The watch only powers live
    // incremental updates — it is NOT required for the initial backfill, and
    // periodic sync still picks up changes without it. A watch failure (e.g.
    // a transient Google API error, or an environment without an HTTPS
    // webhook endpoint) must therefore never abort sync setup before the
    // sync batch below is queued, or the calendar would never populate.
    try {
      await this.setupCalendarWatch(resolvedCalendarId);
    } catch (error) {
      console.error(
        `Failed to set up calendar watch for ${resolvedCalendarId}; continuing with sync (live updates disabled until next renewal):`,
        error
      );
    }

    // Determine sync range
    let min: Date | null;
    if (timeMin === null) {
      min = null;
    } else if (timeMin !== undefined) {
      min = timeMin;
    } else {
      const now = new Date();
      min = new Date(now.getFullYear() - 2, 0, 1);
    }

    let max: Date | null = null;
    if (timeMax !== null && timeMax !== undefined) {
      max = timeMax;
    }

    const initialState: SyncState = {
      calendarId: resolvedCalendarId,
      min,
      max,
      sequence: 1,
    };

    await this.set(`sync_state_${resolvedCalendarId}`, initialState);

    // Start sync batch
    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "full",
      resolvedCalendarId,
      true // initialSync = true
    );
    await this.runTask(syncCallback);
  }

  async stopSync(calendarId: string): Promise<void> {
    // 1. Cancel the scheduled renewal task for this calendar.
    await this.cancelScheduledTask(`watch-renewal:${calendarId}`);

    // 2. Stop watch via Google API (best effort)
    try {
      await this.stopCalendarWatch(calendarId);
    } catch (error) {
      console.warn(
        "Failed to stop calendar watch:",
        error instanceof Error ? error.message : error
      );
    }

    // 3. Clear sync-related storage and release the framework-managed lock.
    await this.clear(`calendar_watch_${calendarId}`);
    await this.clear(`sync_state_${calendarId}`);
    await this.clear(`auth_token_${calendarId}`);
    await this.tools.store.releaseLock(`sync_${calendarId}`);

    // 4. Clear any leftover `pending_occ:` / `seen_master:` markers so a
    // future re-enable starts from a clean slate (no stale buffers from
    // a crashed run sitting around to corrupt the next orphan flush).
    await this.clearBuffers(calendarId);
  }

  /**
   * Clear all `pending_occ:` and `seen_master:` markers for one calendar.
   * Used on recovery, stopSync, and sync-error paths.
   */
  private async clearBuffers(calendarId: string): Promise<void> {
    return clearBuffersFn(this.makeHost(), calendarId);
  }

  /**
   * Stop a calendar watch by calling the Google Calendar API.
   * This cancels the webhook subscription with Google.
   *
   * @private
   */
  private async stopCalendarWatch(
    calendarId: string,
    existingApi?: GoogleApi
  ): Promise<void> {
    return stopCalendarWatchFn(this.makeHost(), calendarId, existingApi);
  }

  /**
   * Schedule proactive renewal of a calendar watch 24 hours before expiry.
   * Creates a callback to renewCalendarWatch and schedules it using the Tasks tool.
   *
   * @private
   */
  private async scheduleWatchRenewal(calendarId: string): Promise<void> {
    const schedule = await getWatchRenewalScheduleFn(this.makeHost(), calendarId);
    if (!schedule) return;

    if ("immediate" in schedule) {
      // Already past the renewal window — renew now.
      await this.renewCalendarWatch(calendarId);
      return;
    }

    const renewalCallback = await this.callback(
      this.renewCalendarWatch,
      calendarId
    );
    // Durable recurring: ceiling 3.5 days (half the ~7-day watch) guarantees a
    // renewal fires even if a precise beat is lost; firstRunAt keeps the precise
    // expiry-24h timing. renewCalendarWatch re-registers on success (the tighten path).
    await this.scheduleRecurring(`watch-renewal:${calendarId}`, renewalCallback, schedule);
  }

  /**
   * Renew a calendar watch by creating a new watch.
   * This is called either proactively (scheduled task) or reactively (on webhook).
   * Gracefully handles errors without throwing.
   *
   * @private
   */
  private async renewCalendarWatch(calendarId: string): Promise<void> {
    try {
      const oldWatchData = await this.get<any>(`calendar_watch_${calendarId}`);
      if (!oldWatchData) {
        console.warn(
          `No watch data found for calendar ${calendarId}, skipping renewal`
        );
        return;
      }

      // setupCalendarWatch is idempotent — it stops the existing watch and
      // re-schedules the (keyed) renewal — so no separate teardown is needed.
      await this.setupCalendarWatch(calendarId);
    } catch (error) {
      console.error(`Failed to renew watch for calendar ${calendarId}:`, error);
    }
  }

  private async setupCalendarWatch(calendarId: string): Promise<void> {
    const webhookUrl = await this.tools.network.createWebhook(
      {},
      this.onCalendarWebhook,
      calendarId
    );

    try {
      const result = await setupCalendarWatchFn(this.makeHost(), webhookUrl, calendarId);
      if ("skipped" in result) return;
      // Schedule proactive renewal 24 hours before expiry.
      await this.scheduleWatchRenewal(calendarId);
    } catch (error) {
      console.error(
        `Failed to setup calendar watch for calendar ${calendarId}:`,
        error
      );
      throw error;
    }
  }

  /**
   * Processes one batch of calendar events and schedules the next batch if
   * required. Delegates all state-machine logic to {@link runSyncBatch}.
   */
  async syncBatch(
    batchNumber: number,
    mode: "full" | "incremental",
    calendarId: string,
    initialSync: boolean
  ): Promise<void> {
    const result = await runSyncBatch(
      this.makeHost(),
      batchNumber,
      mode,
      calendarId,
      initialSync
    );
    if ("done" in result) return;
    const nextCallback = await this.callback(
      this.syncBatch,
      result.next.batchNumber,
      result.next.mode,
      calendarId,
      initialSync
    );
    await this.runTask(nextCallback);
  }

  async onCalendarWebhook(
    request: WebhookRequest,
    calendarId: string
  ): Promise<void> {
    const validation = await validateCalendarWebhookFn(
      this.makeHost(),
      request,
      calendarId
    );
    if ("invalid" in validation) return;

    if (validation.needsRenewal) {
      this.renewCalendarWatch(calendarId).catch((error) => {
        console.error(
          `Failed to reactively renew watch for ${calendarId}:`,
          error
        );
      });
    }

    await this.startIncrementalSync(calendarId);
  }

  private async startIncrementalSync(calendarId: string): Promise<void> {
    const result = await startIncrementalSyncFn(this.makeHost(), calendarId);
    if ("done" in result) return;

    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "incremental",
      calendarId,
      false
    );
    await this.runTask(syncCallback);
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
    _actor: Actor
  ): Promise<void> {
    const params = extractRSVPParamsFn(thread, status);
    if (!params) return;

    const { calendarId, eventId, googleStatus } = params;

    try {
      const api = await this.getApi(calendarId);
      await updateEventRSVPWithApiFn(api, calendarId, eventId, googleStatus);
    } catch (error) {
      console.error("[RSVP Sync] Failed to sync RSVP", {
        event_id: eventId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  /**
   * Called when a user changes an event link's status in Plot. Only
   * "Cancelled" write-backs here: "Confirmed"/"Tentative" just mirror
   * Google's own `event.status` and aren't meaningfully user-settable for
   * events you organize. Deleting the event (rather than PATCHing
   * status=cancelled, which Google only documents as reliable for
   * recurring instance exceptions) mirrors how a real cancellation arrives
   * from Google, so the next incremental sync's already-tested
   * cancellation path archives the schedule and removes it from the
   * agenda. Best-effort: a failed write-back is reconciled by the user
   * retrying the status change.
   */
  async onLinkUpdated(link: Link): Promise<void> {
    if (link.status !== "Cancelled") return;

    const calendarId = link.channelId;
    const eventId = (link.meta as Record<string, unknown> | null)?.id as
      | string
      | undefined;
    if (!calendarId || !eventId) return;

    try {
      const api = await this.getApi(calendarId);
      await cancelEventWithApiFn(api, calendarId, eventId);
    } catch (error) {
      console.error("[GoogleCalendar] onLinkUpdated write-back failed:", {
        event_id: eventId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
}

export default GoogleCalendar;
