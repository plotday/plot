import {
  type Action,
  ActionType,
  type Actor,
  type ActorId,
  ConferencingProvider,
  type ContentType,
  type NewLinkWithNotes,
  type NewContact,
  Connector,
  type Thread,
  type ToolBuilder,
} from "@plotday/twister";
import type { ScheduleContactStatus } from "@plotday/twister/schedule";
import type {
  NewScheduleContact,
  NewScheduleOccurrence,
} from "@plotday/twister/schedule";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";

type Calendar = {
  id: string;
  name: string;
  description: string | null;
  primary: boolean;
};

type SyncOptions = {
  timeMin?: Date | null;
  timeMax?: Date | null;
};

import {
  GraphApi,
  type SyncState,
  syncOutlookCalendar,
  transformOutlookEvent,
} from "./graph-api";

/**
 * Detects the conferencing provider from a URL
 */
function detectConferencingProvider(url: string): ConferencingProvider {
  const lowerUrl = url.toLowerCase();

  if (lowerUrl.includes("zoom.us")) {
    return ConferencingProvider.zoom;
  }
  if (
    lowerUrl.includes("teams.microsoft.com") ||
    lowerUrl.includes("teams.live.com")
  ) {
    return ConferencingProvider.microsoftTeams;
  }
  if (lowerUrl.includes("webex.com")) {
    return ConferencingProvider.webex;
  }
  if (lowerUrl.includes("meet.google.com")) {
    return ConferencingProvider.googleMeet;
  }

  // Default to microsoftTeams for Outlook events
  return ConferencingProvider.microsoftTeams;
}

/**
 * Build canonical identifiers for an Outlook event. First element is the
 * connector-native source (mailbox-qualified for global uniqueness).
 * Additional elements are cross-vendor aliases so other connectors can bundle
 * via `icaluid:<UID>` or `outlook-event:<id>` without knowing our exact
 * `outlook-calendar:<calendarId>:<eventId>` format.
 */
function buildEventSources(opts: {
  calendarId: string;
  eventId?: string | null;
  iCalUId?: string | null;
  seriesMasterId?: string | null;
}): string[] {
  const { calendarId, eventId, iCalUId, seriesMasterId } = opts;
  const sources: string[] = [];
  const primaryId = eventId ?? seriesMasterId;
  if (primaryId) sources.push(`outlook-calendar:${calendarId}:${primaryId}`);
  if (iCalUId) sources.push(`icaluid:${iCalUId}`);
  if (eventId) sources.push(`outlook-event:${eventId}`);
  return sources;
}

type WatchState = {
  subscriptionId: string;
  calendarId: string;
  expiry: Date;
};

/**
 * Short stable hash of a string for use in note keys. Same content
 * produces the same key (idempotent upsert on re-sync); edited content
 * produces a different key (new note, prior versions preserved as
 * history on the thread).
 */
async function hashContent(content: string): Promise<string> {
  const data = new TextEncoder().encode(content);
  const buf = await crypto.subtle.digest("SHA-256", data);
  const bytes = new Uint8Array(buf);
  let hex = "";
  for (let i = 0; i < 8; i++) {
    hex += bytes[i].toString(16).padStart(2, "0");
  }
  return hex;
}

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
  static readonly SCOPES = ["https://graph.microsoft.com/calendars.readwrite"];

  readonly provider = AuthProvider.Microsoft;
  readonly channelNoun = { singular: "calendar", plural: "calendars" };
  readonly autoEnableNewChannelsByDefault = true;
  readonly scopes = OutlookCalendar.SCOPES;
  readonly access = [
    "Reads your events to add them to your agenda",
    "Writes your event RSVPs",
  ];
  readonly linkTypes = [{ type: "event", label: "Event", sharingModel: "thread" as const, includesSchedules: true, logo: "https://api.iconify.design/logos/microsoft-icon.svg", logoDark: "https://api.iconify.design/simple-icons/microsoftoutlook.svg?color=%230078D4", logoMono: "https://api.iconify.design/simple-icons/microsoftoutlook.svg" }];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://graph.microsoft.com/*"] }),
    };
  }

  // Lock TTL covering the worst-case full backfill. The framework releases
  // the lock automatically after this window even if a worker crashes, so
  // no stuck-sync recovery is needed.
  private static readonly SYNC_LOCK_TTL_MS = 2 * 60 * 60 * 1000;

  // Renew subscription this far before expiry. MS Graph caps calendar
  // subscriptions at ~3 days; without renewal every connection's webhook
  // silently dies after 72 hours.
  private static readonly RENEWAL_LEAD_MS = 24 * 60 * 60 * 1000;

  // Maximum subscription lifetime allowed by MS Graph for calendar
  // resources. Used when creating/renewing subscriptions.
  private static readonly SUBSCRIPTION_DURATION_DAYS = 3;

  /**
   * Returns available Outlook calendars as channel resources.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    const api = new GraphApi(token.token);
    const calendars = await api.getCalendars();
    return calendars.map((c) => ({ id: c.id, title: c.name }));
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
      // Stop the existing MS Graph subscription and cancel any pending
      // renewal task BEFORE initCalendar runs. setupOutlookWatch
      // unconditionally creates a fresh subscription and overwrites
      // `outlook_watch_${calendarId}`; without this cleanup the old
      // subscription is orphaned on Microsoft's side (firing webhooks
      // until expiry to a connector that no longer recognises them)
      // and the old renewal-task token is overwritten in storage
      // (the old task still fires when scheduled, wasting a slot).
      const oldRenewalTask = await this.get<string>(
        `outlook_watch_renewal_task_${channel.id}`
      );
      if (oldRenewalTask) {
        await this.cancelTask(oldRenewalTask);
        await this.clear(`outlook_watch_renewal_task_${channel.id}`);
      }
      const oldWatchData = await this.get<WatchState>(
        `outlook_watch_${channel.id}`
      );
      if (oldWatchData?.subscriptionId) {
        // tryGetApi handles the token-missing case cleanly — recovery
        // is precisely the path where a stale or invalid token is
        // plausible, so don't throw if the auth state isn't usable.
        const api = await this.tryGetApi(
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
      await this.clearBuffers(channel.id);
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
   */
  async initCalendar(calendarId: string): Promise<void> {
    // Auth-token presence check up front: getApi() throws if the token
    // was cleared, and as a queued task that throw becomes a retry loop.
    // Skip cleanly instead.
    const api = await this.tryGetApi(calendarId, "initCalendar");
    if (!api) {
      return;
    }

    // Acquire sync lock. Self-expires after SYNC_LOCK_TTL_MS so a crashed
    // worker can't wedge sync forever. Bails if another sync is in flight.
    const acquired = await this.tools.store.acquireLock(
      `sync_${calendarId}`,
      OutlookCalendar.SYNC_LOCK_TTL_MS
    );
    if (!acquired) {
      return;
    }

    // Setup webhook for this calendar
    await this.setupOutlookWatch(calendarId);

    // Two-pass initial sync:
    // - Quick pass (`phase: "quick"`) walks `timeMin = now` so upcoming
    //   meetings surface in the activity feed immediately.
    // - Full pass (`phase: "full"`, queued at the terminal batch of the
    //   quick pass) walks the 2-year historical backfill.
    // Both passes share the sync lock acquired above. The quick→full
    // transition happens inside syncOutlookBatch without releasing.
    const initialState: SyncState = {
      calendarId,
      min: new Date(),
      sequence: 1,
      phase: "quick",
    };

    await this.set(`outlook_sync_state_${calendarId}`, initialState);

    // Start first sync batch
    const syncCallback = await this.callback(
      this.syncOutlookBatch,
      calendarId,
      true, // initialSync
      1 // batchNumber
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

  /**
   * Stamp the first time the connector observes some opaque key, and
   * reuse that timestamp on every subsequent observation. Used for
   * description note `created` timestamps: Outlook's
   * `lastModifiedDateTime` bumps on any edit (e.g. attendee changes),
   * so re-using it as `created` would drag the description note
   * forward in the activity feed on unrelated updates. `firstSeenAt`
   * anchors `created` to the first observation per content hash.
   */
  private async firstSeenAt(storeKey: string): Promise<Date> {
    const existing = await this.get<string>(storeKey);
    if (existing) return new Date(existing);
    const now = new Date();
    await this.set(storeKey, now.toISOString());
    return now;
  }

  private async getApi(calendarId: string): Promise<GraphApi> {
    const token = await this.tools.integrations.get(calendarId);
    if (!token) {
      throw new Error("No Microsoft authentication token available");
    }
    return new GraphApi(token.token);
  }

  /**
   * Non-throwing variant of getApi(): logs a warning and returns null
   * when the auth token is missing. Used by queued tasks so a cleared
   * token doesn't turn into an infinite retry loop. Callers remain
   * responsible for releasing any held lock and clearing sync state on
   * null (cleanup varies per call site).
   */
  private async tryGetApi(
    calendarId: string,
    label: string
  ): Promise<GraphApi | null> {
    const token = await this.tools.integrations.get(calendarId);
    if (!token) {
      console.warn(
        `Auth token missing for calendar ${calendarId} during ${label}, skipping`
      );
      return null;
    }
    return new GraphApi(token.token);
  }

  private async getUserEmail(calendarId: string): Promise<string> {
    const api = await this.getApi(calendarId);
    const data = (await api.call(
      "GET",
      "https://graph.microsoft.com/v1.0/me"
    )) as { mail?: string; userPrincipalName?: string };

    return data.mail || data.userPrincipalName || "";
  }

  private async ensureUserIdentity(calendarId: string): Promise<string> {
    // Check if we already have the user email stored
    const stored = await this.get<string>("user_email");
    if (stored) {
      return stored;
    }

    // Fetch user email from Microsoft Graph
    const email = await this.getUserEmail(calendarId);

    // Store for future use
    await this.set("user_email", email);
    return email;
  }

  async getCalendars(calendarId: string): Promise<Calendar[]> {
    const api = await this.getApi(calendarId);
    return await api.getCalendars();
  }

  async startSync(
    options: {
      calendarId: string;
    } & SyncOptions,
  ): Promise<void> {
    const { calendarId, timeMin, timeMax } = options;

    const acquired = await this.tools.store.acquireLock(
      `sync_${calendarId}`,
      OutlookCalendar.SYNC_LOCK_TTL_MS
    );
    if (!acquired) {
      return;
    }

    // Setup webhook for this calendar
    await this.setupOutlookWatch(calendarId);

    // Determine sync range
    let min: Date | undefined;
    if (timeMin === null) {
      // null means sync all history
      min = undefined;
    } else if (timeMin !== undefined) {
      // User provided a specific minimum date
      min = timeMin;
    } else {
      // Default to 2 years into the past
      const now = new Date();
      min = new Date(now.getFullYear() - 2, 0, 1);
    }

    // Handle timeMax (null means no limit, same as undefined)
    let max: Date | undefined;
    if (timeMax !== null && timeMax !== undefined) {
      max = timeMax;
    }

    // Initialize sync state with min and max
    await this.set(`outlook_sync_state_${calendarId}`, {
      calendarId,
      min,
      max,
      sequence: 1,
    } as SyncState);

    // Start sync batch using runTask for batched processing
    const syncCallback = await this.callback(
      this.syncOutlookBatch,
      calendarId,
      true, // initialSync = true for initial sync
      1 // batchNumber = 1 for first batch
    );
    await this.runTask(syncCallback);
  }

  async stopSync(calendarId: string): Promise<void> {
    // 1. Cancel scheduled renewal task
    const renewalTask = await this.get<string>(
      `outlook_watch_renewal_task_${calendarId}`
    );
    if (renewalTask) {
      await this.cancelTask(renewalTask);
      await this.clear(`outlook_watch_renewal_task_${calendarId}`);
    }

    // 2. Stop webhook subscription (best effort)
    const watchData = await this.get<WatchState>(`outlook_watch_${calendarId}`);
    if (watchData?.subscriptionId) {
      try {
        const api = await this.getApi(calendarId);
        await api.deleteSubscription(watchData.subscriptionId);
      } catch (error) {
        console.error("Failed to delete Outlook subscription:", error);
        // Continue to clear local state even if API call fails
      }
      await this.clear(`outlook_watch_${calendarId}`);
    }

    // 3. Clear sync state and release the framework-managed lock.
    await this.clear(`outlook_sync_state_${calendarId}`);
    await this.tools.store.releaseLock(`sync_${calendarId}`);

    // 4. Clear any leftover `pending_occ:` / `seen_master:` markers so a
    // future re-enable starts from a clean slate (no stale buffers from
    // a crashed run sitting around to corrupt the next orphan flush).
    await this.clearBuffers(calendarId);
  }

  /**
   * Clear all `pending_occ:` and `seen_master:` markers for one calendar.
   * Used on recovery, stopSync, and sync-error paths so stale buffers
   * from a crashed run can't combine with leftover seen-master markers
   * to materialise empty Untitled threads on the next initial sync.
   *
   * Outlook's source format (`outlook-calendar:<calendarId>:<eventId>`)
   * is already calendar-scoped, so derived storage keys naturally
   * partition by calendar via the source-prefix.
   */
  private async clearBuffers(calendarId: string): Promise<void> {
    const pendingKeys = await this.tools.store.list(
      `pending_occ:outlook-calendar:${calendarId}:`
    );
    for (const key of pendingKeys) {
      await this.clear(key);
    }
    const seenMasterKeys = await this.tools.store.list(
      `seen_master:outlook-calendar:${calendarId}:`
    );
    for (const key of seenMasterKeys) {
      await this.clear(key);
    }
  }

  /**
   * Schedule proactive renewal of an Outlook subscription 24 hours before
   * expiry. MS Graph caps calendar subscriptions at ~3 days, so without
   * renewal every connection's webhook silently dies after 72 hours.
   *
   * @private
   */
  private async scheduleSubscriptionRenewal(calendarId: string): Promise<void> {
    const watchData = await this.get<WatchState>(
      `outlook_watch_${calendarId}`
    );
    if (!watchData?.expiry) {
      console.warn(`No watch data found for calendar ${calendarId}`);
      return;
    }

    // Calculate renewal time: RENEWAL_LEAD_MS before expiry
    const expiry =
      watchData.expiry instanceof Date
        ? watchData.expiry
        : new Date(watchData.expiry);
    const renewalTime = new Date(
      expiry.getTime() - OutlookCalendar.RENEWAL_LEAD_MS
    );

    // Don't schedule if already past renewal time (edge case)
    if (renewalTime <= new Date()) {
      await this.renewOutlookWatch(calendarId);
      return;
    }

    // Create callback for renewal (only pass calendarId - serializable!)
    const renewalCallback = await this.callback(
      this.renewOutlookWatch,
      calendarId
    );

    // Schedule renewal task
    const taskToken = await this.runTask(renewalCallback, {
      runAt: renewalTime,
    });

    // Store task token for cleanup
    if (taskToken) {
      await this.set(`outlook_watch_renewal_task_${calendarId}`, taskToken);
    }
  }

  /**
   * Renew an Outlook subscription by extending its expiry via PATCH.
   * Called either proactively (scheduled task) or reactively (on webhook).
   * Gracefully handles errors without throwing.
   *
   * @private
   */
  async renewOutlookWatch(calendarId: string): Promise<void> {
    try {
      const oldWatchData = await this.get<WatchState>(
        `outlook_watch_${calendarId}`
      );
      if (!oldWatchData?.subscriptionId) {
        console.warn(
          `No watch data found for calendar ${calendarId}, skipping renewal`
        );
        return;
      }

      const api = await this.tryGetApi(calendarId, "renewOutlookWatch");
      if (!api) {
        return;
      }

      // PATCH the subscription to extend the expiry. Keeps the
      // subscription id stable, so we don't have to re-create the watch
      // state or invalidate any client validation that already happened.
      const newExpiry = new Date();
      newExpiry.setDate(
        newExpiry.getDate() + OutlookCalendar.SUBSCRIPTION_DURATION_DAYS
      );

      try {
        await api.renewSubscription(oldWatchData.subscriptionId, newExpiry);
        const updatedWatchState: WatchState = {
          ...oldWatchData,
          expiry: newExpiry,
        };
        await this.set(`outlook_watch_${calendarId}`, updatedWatchState);

        // Schedule the next renewal 24h before the new expiry.
        await this.scheduleSubscriptionRenewal(calendarId);
      } catch (error) {
        console.warn(
          `PATCH renewal failed for ${calendarId}, falling back to delete+recreate:`,
          error
        );
        // Fallback: delete + recreate. setupOutlookWatch reschedules the
        // next renewal task at the end.
        try {
          await api.deleteSubscription(oldWatchData.subscriptionId);
        } catch (delErr) {
          console.warn(
            `Failed to delete old subscription for ${calendarId}:`,
            delErr
          );
        }
        await this.clear(`outlook_watch_${calendarId}`);
        await this.setupOutlookWatch(calendarId);
      }
    } catch (error) {
      console.error(
        `Failed to renew Outlook subscription for ${calendarId}:`,
        error
      );
    }
  }

  async setupOutlookWatch(calendarId: string): Promise<void> {
    // Auth-token presence check up front: getApi() throws if the token
    // was cleared, and as a queued task that throw becomes a retry loop.
    // Skip cleanly instead.
    const api = await this.tryGetApi(calendarId, "setupOutlookWatch");
    if (!api) {
      return;
    }

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

    // Skip webhook setup for localhost (development mode)
    if (webhookUrl.includes("localhost") || webhookUrl.includes("127.0.0.1")) {
      return;
    }

    // Microsoft Graph subscriptions expire — set expiry to the maximum
    // allowed lifetime for calendar resources.
    const expirationDate = new Date();
    expirationDate.setDate(
      expirationDate.getDate() + OutlookCalendar.SUBSCRIPTION_DURATION_DAYS
    );

    try {
      const subscription = await api.createSubscription(
        calendarId,
        webhookUrl,
        expirationDate
      );

      const watchState: WatchState = {
        subscriptionId: subscription.id,
        calendarId,
        expiry: new Date(subscription.expirationDateTime),
      };

      await this.set(`outlook_watch_${calendarId}`, watchState);

      // Schedule proactive renewal 24 hours before expiry. MS Graph caps
      // subscriptions at ~3 days; without renewal the webhook silently
      // dies after 72 hours.
      await this.scheduleSubscriptionRenewal(calendarId);
    } catch (error) {
      console.error("Failed to setup Outlook webhook:", error);
      // Continue without webhook - sync will still work via manual triggers
    }
  }

  async syncOutlookBatch(
    calendarId: string,
    initialSync: boolean,
    batchNumber: number = 1
  ): Promise<void> {
    try {
      // Auth-token presence check up front: getApi() throws if the token
      // was cleared, and as a queued task that throw becomes a retry loop.
      // Skip cleanly instead.
      const api = await this.tryGetApi(
        calendarId,
        `syncOutlookBatch (batch ${batchNumber})`
      );
      if (!api) {
        await this.clear(`outlook_sync_state_${calendarId}`);
        await this.tools.store.releaseLock(`sync_${calendarId}`);
        return;
      }

      // Ensure we have the user's identity for RSVP tagging (only on first batch)
      if (batchNumber === 1) {
        await this.ensureUserIdentity(calendarId);
      }

      // Load existing sync state
      const savedState = await this.get<SyncState>(
        `outlook_sync_state_${calendarId}`
      );

      const syncState: SyncState = savedState || {
        calendarId,
        sequence: 1,
      };

      // Restore Date objects from JSON (Date is serialized to string)
      if (syncState.min && typeof syncState.min === "string") {
        syncState.min = new Date(syncState.min);
      }
      if (syncState.max && typeof syncState.max === "string") {
        syncState.max = new Date(syncState.max);
      }

      // Process ONE batch (single API page) instead of while loop
      const result = await syncOutlookCalendar(api, calendarId, syncState);

      // Preserve phase across pagination (syncOutlookCalendar in
      // graph-api.ts doesn't propagate it).
      result.state.phase = syncState.phase;

      // Process events
      await this.processOutlookEvents(
        result.events,
        calendarId,
        initialSync
      );

      console.log(
        `Synced ${result.events.length} events in batch ${batchNumber} for calendar ${calendarId}`
      );

      // Save sync state
      await this.set(`outlook_sync_state_${calendarId}`, result.state);

      // Queue next batch as separate task if there's more
      if (result.state.more) {
        const syncCallback = await this.callback(
          this.syncOutlookBatch,
          calendarId,
          initialSync,
          batchNumber + 1
        );
        await this.runTask(syncCallback);
      } else {
        // Quick pass done: transition to full pass without releasing
        // the lock. The full pass walks the historical range
        // (timeMin = 2y ago) and picks up long-running recurring
        // masters that timeMin = now excluded. Any exception
        // instances the quick pass buffered into pending_occ: are
        // carried across; they're only cleared when the full pass
        // completes below.
        if (syncState.phase === "quick") {
          const historyMin = new Date();
          historyMin.setFullYear(historyMin.getFullYear() - 2);
          historyMin.setMonth(0, 1);
          historyMin.setHours(0, 0, 0, 0);
          const fullState: SyncState = {
            calendarId,
            min: historyMin,
            sequence: 1,
            phase: "full",
          };
          await this.set(`outlook_sync_state_${calendarId}`, fullState);
          const fullCallback = await this.callback(
            this.syncOutlookBatch,
            calendarId,
            initialSync,
            1
          );
          await this.runTask(fullCallback);
          return;
        }

        console.log(
          `Outlook Calendar sync completed after ${batchNumber} batches for calendar ${calendarId}`
        );

        // Full pass terminal: flush leftover pending_occ buffers as
        // standalone occurrence-only links — but ONLY when their
        // master was actually processed during this initial sync
        // (and is therefore in the DB by now). seen_master:<canonical>
        // markers track which canonicals showed up in any batch.
        //
        // When a leftover's master never appeared, the master is gone
        // from Outlook (deleted upstream). Flushing in that case would
        // INSERT a brand-new link/thread with no schedule, no title,
        // no notes. Drop those orphans silently instead.
        if (initialSync) {
          const seenMasterKeys = await this.tools.store.list("seen_master:");
          const seenMasters = new Set(
            seenMasterKeys.map((k) => k.slice("seen_master:".length))
          );
          const pendingKeys = await this.tools.store.list("pending_occ:");
          const flushLinks: NewLinkWithNotes[] = [];
          let droppedOrphans = 0;
          for (const key of pendingKeys) {
            const pending = await this.get<NewScheduleOccurrence>(key);
            if (!pending) {
              await this.clear(key);
              continue;
            }
            const occurrenceDate =
              pending.occurrence instanceof Date
                ? pending.occurrence
                : new Date(pending.occurrence as unknown as string);
            const suffix = `:${occurrenceDate.toISOString()}`;
            if (!key.startsWith("pending_occ:") || !key.endsWith(suffix)) {
              // Malformed key — drop it.
              await this.clear(key);
              continue;
            }
            const canonical = key.slice(
              "pending_occ:".length,
              key.length - suffix.length
            );
            if (!seenMasters.has(canonical)) {
              droppedOrphans += 1;
              await this.clear(key);
              continue;
            }
            flushLinks.push({
              type: "event",
              title: "",
              source: canonical,
              channelId: calendarId,
              meta: { syncProvider: "microsoft", syncableId: calendarId },
              scheduleOccurrences: [pending],
              notes: [],
            });
            await this.clear(key);
          }
          if (flushLinks.length > 0 || droppedOrphans > 0) {
            console.log(
              `[OutlookCalendar] full-pass flush: calendar=${calendarId} ` +
                `flushedLinks=${flushLinks.length} ` +
                `droppedOrphans=${droppedOrphans}`
            );
          }
          if (flushLinks.length > 0) {
            await this.tools.integrations.saveLinks(flushLinks);
          }

          // Clear master markers for the next initial sync.
          for (const key of seenMasterKeys) {
            await this.clear(key);
          }
        }

        // Initial sync is fully complete — clear the "syncing…" indicator
        // on the connection. Gated on initialSync (not phase), so a
        // corrupted state that bypassed the quick→full transition still
        // signals completion instead of leaving the UI stuck on "Syncing".
        if (initialSync) {
          await this.tools.integrations.channelSyncCompleted(calendarId);
        }

        // Release lock when sync completes (no more batches).
        await this.tools.store.releaseLock(`sync_${calendarId}`);
      }
    } catch (error) {
      console.error(
        `Outlook Calendar sync failed for ${calendarId} in batch ${batchNumber}:`,
        error
      );

      // Release lock and clear state so future syncs aren't permanently
      // blocked. Even if this release fails, the lock's TTL will expire it.
      await this.tools.store.releaseLock(`sync_${calendarId}`);
      await this.clear(`outlook_sync_state_${calendarId}`);

      // Clear any `pending_occ:` / `seen_master:` markers buffered by
      // this run. Otherwise the next initial sync would inherit them and
      // the full-pass orphan flush could materialise empty Untitled
      // threads from leftover-but-now-stale buffers.
      try {
        await this.clearBuffers(calendarId);
      } catch (cleanupError) {
        console.error(
          `Failed to clear pending buffers after sync error for ${calendarId}:`,
          cleanupError
        );
      }

      // The runtime auto-clears the "Syncing…" indicator when
      // onChannelEnabled itself throws, but NOT when a queued task
      // throws. Without an explicit signal here, the indicator stays on
      // indefinitely after a mid-sync crash until the user disables and
      // re-enables. Inner try/catch so a signal failure doesn't mask
      // the original error.
      if (initialSync) {
        try {
          await this.tools.integrations.channelSyncCompleted(calendarId);
        } catch (signalError) {
          console.error(
            "Failed to signal sync completion on error path:",
            signalError
          );
        }
      }

      // Re-throw to let the caller handle it
      throw error;
    }
  }

  /**
   * Process Outlook events from a sync batch.
   *
   * Coalesces all events keyed by canonical `source` so a master and
   * any number of its exception instances collapse into a single
   * NewLinkWithNotes. The final saveLinks call makes one cross-runtime
   * RPC for the entire page. Heavy recurring meetings with many
   * exceptions used to fire N+1 saveLink calls; now they fire one.
   */
  private async processOutlookEvents(
    events: import("./graph-api").OutlookEvent[],
    calendarId: string,
    initialSync: boolean
  ): Promise<void> {
    const linksBySource = new Map<string, NewLinkWithNotes>();
    type LinkWithSource = NewLinkWithNotes & { source: string };
    const addLink = (link: LinkWithSource) => {
      const existing = linksBySource.get(link.source) as
        | LinkWithSource
        | undefined;
      if (!existing) {
        linksBySource.set(link.source, link);
        return;
      }
      // Merge occurrences and notes. Prefer the fuller entry (master)
      // when only one side carries the series-level fields (schedules,
      // title, ...).
      existing.scheduleOccurrences = [
        ...(existing.scheduleOccurrences || []),
        ...(link.scheduleOccurrences || []),
      ];
      if (link.notes?.length) {
        existing.notes = [...(existing.notes || []), ...link.notes];
      }
      if (link.schedules && !existing.schedules) {
        existing.schedules = link.schedules;
        existing.title = link.title ?? existing.title;
        existing.type = link.type ?? existing.type;
        existing.actions = link.actions ?? existing.actions;
        existing.sourceUrl = link.sourceUrl ?? existing.sourceUrl;
        existing.preview = link.preview ?? existing.preview;
        existing.access = link.access ?? existing.access;
        existing.accessContacts =
          link.accessContacts ?? existing.accessContacts;
        existing.author = link.author ?? existing.author;
        existing.created = link.created ?? existing.created;
        existing.meta = { ...(existing.meta || {}), ...(link.meta || {}) };
        if (link.unread !== undefined) existing.unread = link.unread;
        if (link.archived !== undefined) existing.archived = link.archived;
      }
    };

    for (const outlookEvent of events) {
      try {
        // Handle deleted events
        if (outlookEvent["@removed"]) {
          // On initial sync, skip creating threads for already-deleted events
          if (initialSync) {
            continue;
          }
          // Graph event ids are mailbox-local, so qualify with calendarId
          // to keep source globally unique across users.
          const source = `outlook-calendar:${calendarId}:${outlookEvent.id}`;

          // Create cancellation note. We don't apply firstSeenAt here
          // because cancelled events aren't typically edited further,
          // so lastModifiedDateTime is stable.
          const cancelNote = {
            key: "cancellation" as const,
            content: "This event was cancelled.",
            contentType: "text" as const,
            created: outlookEvent.lastModifiedDateTime
              ? new Date(outlookEvent.lastModifiedDateTime)
              : new Date(),
          };

          // Convert to link with cancellation note
          const link: NewLinkWithNotes = {
            type: "event",
            title: "Cancelled Event",
            created: outlookEvent.createdDateTime
              ? new Date(outlookEvent.createdDateTime)
              : new Date(),
            preview: "Cancelled",
            source,
            sources: buildEventSources({
              calendarId,
              eventId: outlookEvent.id,
              iCalUId: outlookEvent.iCalUId,
            }),
            channelId: calendarId,
            meta: { syncProvider: "microsoft", syncableId: calendarId },
            notes: [cancelNote],
            ...(initialSync ? { unread: false } : {}), // false for initial sync, omit for incremental updates
            ...(initialSync ? { archived: false } : {}), // unarchive on initial sync only
          };

          addLink(link as LinkWithSource);
          continue;
        }

        // Extract contacts from organizer and attendees
        let validAttendees: typeof outlookEvent.attendees = [];

        // Prepare author contact (organizer) - will be passed directly as NewContact
        let authorContact: NewContact | undefined = undefined;
        if (outlookEvent.organizer?.emailAddress?.address) {
          authorContact = {
            email: outlookEvent.organizer.emailAddress.address,
            name: outlookEvent.organizer.emailAddress.name,
          };
        }

        // Prepare attendee contacts for tags
        if (outlookEvent.attendees && outlookEvent.attendees.length > 0) {
          // Filter to get only valid attendees (with email, not resources)
          validAttendees = outlookEvent.attendees.filter(
            (att) => att.emailAddress?.address && att.type !== "resource"
          );
        }

        // Check if this is an exception or occurrence (instance of recurring event)
        if (
          (outlookEvent.type === "exception" ||
            outlookEvent.type === "occurrence") &&
          outlookEvent.seriesMasterId &&
          outlookEvent.originalStart
        ) {
          const instanceLink = await this.prepareEventInstance(
            outlookEvent,
            calendarId,
            initialSync
          );
          if (instanceLink) addLink(instanceLink as LinkWithSource);
          continue;
        }

        // Transform the Outlook event to a Plot thread (master or single events)
        const threadData = transformOutlookEvent(outlookEvent, calendarId);

        // Skip deleted events (transformOutlookEvent returns null for deleted)
        if (!threadData) {
          continue;
        }

        // On initial sync, skip cancelled standalone events
        if (initialSync && outlookEvent.isCancelled) {
          continue;
        }

        // Add contacts to the base schedule so client-generated recurring
        // occurrences inherit attendee data (needed for RSVP buttons).
        // Per-occurrence overrides with their own contacts take precedence.
        if (validAttendees.length > 0 && threadData.schedules?.[0]) {
          const contacts: NewScheduleContact[] = validAttendees.map((attendee) => ({
            contact: {
              email: attendee.emailAddress!.address!,
              name: attendee.emailAddress!.name,
            },
            status: attendee.status?.response === "accepted" ? "attend" as const
              : attendee.status?.response === "declined" ? "skip" as const
              : null,
            role: attendee.type === "required" ? "required" as const
              : attendee.type === "optional" ? "optional" as const
              : "required" as const,
          }));
          threadData.schedules[0].contacts = contacts;
        }

        // Build actions array for videoconferencing and calendar links
        const actions: Action[] = [];

        // Add conferencing link if available
        if (outlookEvent.onlineMeeting?.joinUrl) {
          actions.push({
            type: ActionType.conferencing,
            url: outlookEvent.onlineMeeting.joinUrl,
            provider: detectConferencingProvider(
              outlookEvent.onlineMeeting.joinUrl
            ),
          });
        }

        // Add calendar link
        if (outlookEvent.webLink) {
          actions.push({
            type: ActionType.external,
            title: "View in Calendar",
            url: outlookEvent.webLink,
          });
        }

        const canonicalUrl = `outlook-calendar:${calendarId}:${outlookEvent.id}`;

        // Build description note if available. The key embeds a hash
        // of the description content so each distinct version produces
        // a separate note: re-syncing the same description is an
        // idempotent no-op upsert (same key + same content), while an
        // edited description gets a new key and a fresh note —
        // preserving prior versions as history on the thread. Stamp
        // `created` with the first time we observed each hash and
        // reuse on subsequent syncs, so an unrelated event update
        // (which bumps lastModifiedDateTime on Outlook, e.g. an
        // attendee change) doesn't drag the note forward in the feed.
        const descriptionContent = outlookEvent.body?.content ?? "";
        const hasDescription =
          descriptionContent && descriptionContent.trim().length > 0;
        const hasActions = actions.length > 0;

        const descHash = hasDescription
          ? await hashContent(descriptionContent)
          : null;
        const descFirstSeen = descHash
          ? await this.firstSeenAt(`desc_seen:${canonicalUrl}:${descHash}`)
          : undefined;
        const descriptionNote =
          hasDescription && descHash
            ? {
                key: `description-${descHash}`,
                content: descriptionContent,
                contentType: (outlookEvent.body?.contentType === "html"
                  ? "html"
                  : "text") as ContentType,
                created: descFirstSeen,
              }
            : null;

        // Build attendee contacts for link-level access control
        const attendeeMentions: NewContact[] = [];
        if (authorContact) attendeeMentions.push(authorContact);
        for (const att of validAttendees) {
          if (att.emailAddress?.address) {
            attendeeMentions.push({
              email: att.emailAddress.address,
              name: att.emailAddress.name,
            });
          }
        }

        const notes = descriptionNote ? [descriptionNote] : [];

        // Build NewLinkWithNotes from the transformed thread data
        const linkWithNotes: NewLinkWithNotes = {
          source: canonicalUrl,
          sources: buildEventSources({
            calendarId,
            eventId: outlookEvent.id,
            iCalUId: outlookEvent.iCalUId,
          }),
          type: "event",
          title: threadData.title || "",
          access: "private",
          accessContacts: attendeeMentions,
          created: threadData.created,
          author: authorContact,
          channelId: calendarId,
          meta: {
            ...threadData.meta,
            syncProvider: "microsoft",
            syncableId: calendarId,
          },
          sourceUrl: outlookEvent.webLink ?? null,
          actions: hasActions ? actions : undefined,
          notes,
          preview: hasDescription ? descriptionContent : null,
          schedules: threadData.schedules,
          scheduleOccurrences: threadData.scheduleOccurrences,
          ...(initialSync ? { unread: false } : {}), // false for initial sync, omit for incremental updates
          ...(initialSync ? { archived: false } : {}), // unarchive on initial sync only
        };

        // Coalesce into the batch instead of saving immediately.
        // The end-of-batch drain merges any buffered exception
        // occurrences (pending_occ:) into this master before saveLinks.
        addLink(linkWithNotes as LinkWithSource);
      } catch (error) {
        console.error(`Error processing event ${outlookEvent.id}:`, error);
        // Continue processing other events
      }
    }

    // Drain pending_occ buffers for any masters present in this batch.
    // Done here (after the events loop) so the merge is order-
    // independent within a batch: instances arriving before the master
    // are caught, and instances arriving after the master are caught
    // too (the latter case is what inline merging would miss — it
    // silently lost cancellations whose master happened to come first
    // in the API response).
    let drainedTotal = 0;
    for (const [source, link] of linksBySource.entries()) {
      const pendingPrefix = `pending_occ:${source}:`;
      const pendingKeys = await this.tools.store.list(pendingPrefix);
      if (pendingKeys.length === 0) continue;
      const merged: NewScheduleOccurrence[] = [
        ...(link.scheduleOccurrences || []),
      ];
      for (const key of pendingKeys) {
        const pending = await this.get<NewScheduleOccurrence>(key);
        if (pending) {
          merged.push(pending);
          drainedTotal += 1;
        }
        await this.clear(key);
      }
      link.scheduleOccurrences = merged;
      console.log(
        `[OutlookCalendar] drain: master=${source} ` +
          `merged=${pendingKeys.length} (calendar=${calendarId})`
      );
    }
    if (initialSync) {
      console.log(
        `[OutlookCalendar] processOutlookEvents end: calendar=${calendarId} ` +
          `events=${events.length} masters=${linksBySource.size} ` +
          `drained=${drainedTotal}`
      );

      // Record every master/regular event saved this batch so the
      // full-pass cleanup can distinguish legitimate cross-batch
      // leftovers (master-in-batch-A, instance-in-batch-B → flush is
      // correct, upserts onto the existing master link) from orphans
      // whose master never came through (master deleted upstream →
      // flushing would create a useless empty Untitled thread).
      for (const source of linksBySource.keys()) {
        await this.set(`seen_master:${source}`, true);
      }
    }

    // Single batched save for the whole page. Collapses what used to
    // be one saveLink RPC per event (and one per exception instance
    // on heavy recurring meetings) into a single cross-runtime call.
    const batch = Array.from(linksBySource.values());
    if (batch.length > 0) {
      await this.tools.integrations.saveLinks(batch);
    }
  }

  /**
   * Transform a recurring event instance (occurrence or exception)
   * into either an occurrence-only {@link NewLinkWithNotes} (for the
   * caller's batched saveLinks), or `null` when the occurrence is
   * instead buffered to `pending_occ:` storage for cross-batch
   * merging during initial sync. Never saves directly.
   */
  private async prepareEventInstance(
    event: import("./graph-api").OutlookEvent,
    calendarId: string,
    initialSync: boolean
  ): Promise<NewLinkWithNotes | null> {
    const originalStart = event.originalStart;
    if (!originalStart) {
      console.warn(`No original start time for instance: ${event.id}`);
      return null;
    }

    // The seriesMasterId points to the master thread
    if (!event.seriesMasterId) {
      console.warn(`No series master ID for instance: ${event.id}`);
      return null;
    }

    // Canonical URL for the master recurring event
    const masterCanonicalUrl = `outlook-calendar:${calendarId}:${event.seriesMasterId}`;

    // Transform the instance data
    const instanceData = transformOutlookEvent(event, calendarId);

    if (!instanceData) {
      return null; // Skip deleted events
    }

    // Handle cancelled recurring instances by archiving the occurrence
    if (event.isCancelled) {
      const cancelledOccurrence: NewScheduleOccurrence = {
        occurrence: new Date(originalStart),
        start: new Date(originalStart),
        cancelled: true,
      };

      // During initial sync, buffer the occurrence under a unique key
      // for later merging with its master. Per-occurrence keys keep
      // each write O(1); appending to a shared list would be O(N²)
      // across batches and could blow the worker CPU budget on
      // calendars with many recurring exceptions.
      if (initialSync) {
        const pendingKey = `pending_occ:${masterCanonicalUrl}:${new Date(
          originalStart
        ).toISOString()}`;
        await this.set(pendingKey, cancelledOccurrence);
        console.log(
          `[OutlookCalendar] buffered cancelled instance: ` +
            `master=${masterCanonicalUrl} ` +
            `originalStart=${new Date(originalStart).toISOString()} ` +
            `(calendar=${calendarId})`
        );
        return null;
      }

      return {
        type: "event",
        title: "",
        source: masterCanonicalUrl,
        sources: buildEventSources({
          calendarId,
          seriesMasterId: event.seriesMasterId,
          iCalUId: event.iCalUId,
        }),
        channelId: calendarId,
        meta: { syncProvider: "microsoft", syncableId: calendarId },
        scheduleOccurrences: [cancelledOccurrence],
        notes: [],
      };
    }

    // Build contacts from attendees for this occurrence
    const validAttendees =
      event.attendees?.filter(
        (att) => att.emailAddress?.address && att.type !== "resource"
      ) || [];

    const contacts: NewScheduleContact[] | undefined =
      validAttendees.length > 0
        ? validAttendees.map((attendee) => ({
            contact: {
              email: attendee.emailAddress!.address!,
              name: attendee.emailAddress!.name,
            },
            status: attendee.status?.response === "accepted" ? "attend" as const
              : attendee.status?.response === "declined" ? "skip" as const
              : null,
            role: attendee.type === "required" ? "required" as const
              : attendee.type === "optional" ? "optional" as const
              : "required" as const,
          }))
        : undefined;

    // Build schedule occurrence object
    // Always include start to ensure upsert can infer scheduling when
    // creating a new master thread. Use schedule start from instanceData if
    // available (for rescheduled instances), otherwise fall back to originalStart.
    const instanceSchedule = instanceData.schedules?.[0];
    const occurrenceStart = instanceSchedule?.start ?? new Date(originalStart);

    const occurrence: NewScheduleOccurrence = {
      occurrence: new Date(originalStart),
      start: occurrenceStart,
      contacts,
      ...(initialSync ? { unread: false } : {}),
    };

    // Add end time override if present
    if (instanceSchedule?.end !== undefined && instanceSchedule?.end !== null) {
      occurrence.end = instanceSchedule.end;
    }

    // During initial sync, buffer the occurrence under a unique key
    // for later merging with its master. See the cancelled branch
    // above for why per-occurrence keys replaced the single-list
    // pattern.
    if (initialSync) {
      const pendingKey = `pending_occ:${masterCanonicalUrl}:${new Date(
        originalStart
      ).toISOString()}`;
      await this.set(pendingKey, occurrence);
      console.log(
        `[OutlookCalendar] buffered exception instance: ` +
          `master=${masterCanonicalUrl} ` +
          `originalStart=${new Date(originalStart).toISOString()} ` +
          `(calendar=${calendarId})`
      );
      return null;
    }

    // Incremental sync: return an occurrence-only link. The caller
    // merges it with the master (if the master is in the same batch)
    // or saves it standalone (master already exists in the DB from a
    // prior sync).
    return {
      type: "event",
      title: "",
      source: masterCanonicalUrl,
      sources: buildEventSources({
        calendarId,
        seriesMasterId: event.seriesMasterId,
        iCalUId: event.iCalUId,
      }),
      channelId: calendarId,
      meta: { syncProvider: "microsoft", syncableId: calendarId },
      scheduleOccurrences: [occurrence],
      notes: [],
    };
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
    const watchData = await this.get<WatchState>(
      `outlook_watch_${calendarId}`
    );
    if (watchData?.expiry) {
      const expiry =
        watchData.expiry instanceof Date
          ? watchData.expiry
          : new Date(watchData.expiry);
      const msUntilExpiry = expiry.getTime() - Date.now();
      if (msUntilExpiry < OutlookCalendar.RENEWAL_LEAD_MS) {
        this.renewOutlookWatch(calendarId).catch((error) => {
          console.error(
            `Failed to reactively renew Outlook subscription for ${calendarId}:`,
            error
          );
        });
      }
    }

    for (const notification of notifications) {
      if (notification.changeType) {
        // Trigger incremental sync
        await this.startIncrementalSync(calendarId);
      }
    }
  }

  private async startIncrementalSync(calendarId: string): Promise<void> {
    // Acquire sync lock to prevent the webhook-driven incremental sync
    // from racing an in-progress initial sync (both write to
    // outlook_sync_state_<id>).
    const acquired = await this.tools.store.acquireLock(
      `sync_${calendarId}`,
      OutlookCalendar.SYNC_LOCK_TTL_MS
    );
    if (!acquired) {
      return;
    }

    // Auth-token presence check up front — same retry-loop concern as
    // syncOutlookBatch. Release the lock if we bail.
    const api = await this.tryGetApi(calendarId, "startIncrementalSync");
    if (!api) {
      await this.tools.store.releaseLock(`sync_${calendarId}`);
      return;
    }

    const callback = await this.callback(
      this.syncOutlookBatch,
      calendarId,
      false, // initialSync = false for incremental updates
      1 // batchNumber = 1 for first batch
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
    const meta = thread.meta as Record<string, unknown> | null;
    const calendarId = meta?.syncableId as string | null;
    // Per-mailbox Outlook event id is stored in meta.eventId by
    // transformOutlookEvent. We can't derive it from `source` anymore,
    // because the source format has been qualified with calendarId
    // (`outlook-calendar:<calendarId>:<eventId>`) for cross-user dedup.
    const eventId = meta?.eventId as string | null;

    if (!eventId || !calendarId) return;

    const outlookStatus = status === "attend" ? "accepted" as const
      : status === "skip" ? "declined" as const
      : "tentativelyAccepted" as const;

    try {
      const api = await this.getApi(calendarId);
      await this.updateEventRSVPWithApi(
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

  /**
   * Update RSVP status for the authenticated user on an Outlook Calendar event.
   * Looks up the actor's email from the Graph API to find the correct attendee.
   */
  private async updateEventRSVPWithApi(
    api: GraphApi,
    calendarId: string,
    eventId: string,
    status: "accepted" | "declined" | "tentativelyAccepted",
    _actorId: ActorId
  ): Promise<void> {
    // First, fetch the current event to check if status already matches
    const resource =
      calendarId === "primary"
        ? `/me/events/${eventId}`
        : `/me/calendars/${calendarId}/events/${eventId}`;

    const event = (await api.call(
      "GET",
      `https://graph.microsoft.com/v1.0${resource}`
    )) as any;

    if (!event) {
      throw new Error(`Event ${eventId} not found`);
    }

    // Get the actor's email from the Graph API /me endpoint
    const meData = (await api.call(
      "GET",
      "https://graph.microsoft.com/v1.0/me"
    )) as { mail?: string; userPrincipalName?: string } | null;

    const actorEmail = meData?.mail || meData?.userPrincipalName;
    if (!actorEmail) {
      console.warn("[RSVP Sync] Could not determine actor email");
      return;
    }

    // Check current actor's response status to avoid infinite loops
    const attendees = event.attendees || [];
    const actorAttendee = attendees.find(
      (att: any) =>
        att.emailAddress?.address?.toLowerCase() === actorEmail.toLowerCase()
    );

    if (!actorAttendee) {
      console.warn("[RSVP Sync] Actor is not an attendee of this event", {
        event_id: eventId,
      });
      return;
    }

    if (actorAttendee.status?.response === status) {
      return;
    }

    // Use Microsoft Graph API response endpoints
    const endpoint =
      status === "accepted"
        ? "accept"
        : status === "declined"
        ? "decline"
        : "tentativelyAccept";

    await api.call(
      "POST",
      `https://graph.microsoft.com/v1.0${resource}/${endpoint}`,
      undefined,
      {}
    );
  }
}

export default OutlookCalendar;
