import GoogleContacts, {
  enrichLinkContactsFromGoogle,
} from "@plotday/connector-google-contacts";
import {
  type Action,
  ActionType,
  type Actor,
  type ActorId,
  ConferencingProvider,
  Connector,
  type NewContact,
  type NewLinkWithNotes,
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
  type Channel,
  Integrations,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";

import {
  GoogleApi,
  type GoogleEvent,
  type SyncState,
  containsHtml,
  extractConferencingLinks,
  syncGoogleCalendar,
  transformGoogleEvent,
} from "./google-api";

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
  static readonly SCOPES = [
    "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    "https://www.googleapis.com/auth/calendar.events",
  ];

  readonly provider = AuthProvider.Google;
  readonly scopes = Integrations.MergeScopes(
    GoogleCalendar.SCOPES,
    GoogleContacts.SCOPES
  );
  readonly linkTypes = [
    {
      type: "event",
      label: "Event",
      logo: "https://api.iconify.design/logos/google-calendar.svg",
      logoMono: "https://api.iconify.design/simple-icons/googlecalendar.svg",
      statuses: [
        { status: "Confirmed", label: "Confirmed" },
        { status: "Tentative", label: "Tentative" },
        { status: "Cancelled", label: "Cancelled" },
      ],
    },
  ];

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
    const keys = await this.tools.store.list("sync_lock_");
    for (const key of keys) {
      await this.clear(key);
    }
  }

  /**
   * Returns available calendars as channel resources after authorization.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    const api = new GoogleApi(token.token);
    const calendars = await this.listCalendarsWithApi(api);
    return calendars.map((c) => ({ id: c.id, title: c.name }));
  }

  /**
   * Called when a channel calendar is enabled for syncing.
   * Auto-starts sync for the calendar.
   */
  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    // Store sync_history_min if provided and not already stored with an equal/earlier value
    if (context?.syncHistoryMin) {
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
   */
  async initCalendar(calendarId: string): Promise<void> {
    // Resolve "primary" to actual calendar ID for consistent storage keys
    const resolvedCalendarId = await this.resolveCalendarId(calendarId);

    // Check if sync is already in progress
    const syncInProgress = await this.get<boolean>(
      `sync_lock_${resolvedCalendarId}`
    );
    if (syncInProgress) {
      return;
    }

    // Set sync lock
    await this.set(`sync_lock_${resolvedCalendarId}`, true);

    // Setup webhook for this calendar
    await this.setupCalendarWatch(resolvedCalendarId);

    // Default sync range: 2 years back
    // Quick pass: sync only upcoming events (timeMin = now). Front-loads
    // non-recurring upcoming meetings and future exception instances, which
    // are what users most want to see after connecting. The full pass that
    // follows picks up long-running recurring masters (whose first instance
    // is in the past and is therefore excluded by timeMin = now).
    const initialState: SyncState = {
      calendarId: resolvedCalendarId,
      min: new Date(),
      max: null,
      sequence: 1,
      phase: "quick",
    };

    await this.set(`sync_state_${resolvedCalendarId}`, initialState);

    // Start first sync batch
    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "full",
      resolvedCalendarId,
      true // initialSync = true
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

  private async getApi(calendarId: string): Promise<GoogleApi> {
    // Get token for the syncable (calendar) from integrations
    const token = await this.tools.integrations.get(calendarId);

    if (!token) {
      throw new Error("Authorization no longer available");
    }

    return new GoogleApi(token.token);
  }

  private async listCalendarsWithApi(api: GoogleApi): Promise<Calendar[]> {
    const data = (await api.call(
      "GET",
      "https://www.googleapis.com/calendar/v3/users/me/calendarList"
    )) as {
      items: Array<{
        id: string;
        summary: string;
        description?: string;
        primary?: boolean;
      }>;
    };

    return data.items.map((item) => ({
      id: item.id,
      name: item.summary,
      description: item.description || null,
      primary: item.primary || false,
    }));
  }

  private async getUserEmail(calendarId: string): Promise<string> {
    const api = await this.getApi(calendarId);

    // Use the Calendar API's primary calendar to get the email
    const calendarList = (await api.call(
      "GET",
      "https://www.googleapis.com/calendar/v3/users/me/calendarList/primary"
    )) as { id: string };

    return calendarList.id; // The primary calendar ID is the user's email
  }

  private async ensureUserIdentity(calendarId: string): Promise<string> {
    // Check if we already have the user email stored
    const stored = await this.get<string>("user_email");
    if (stored) {
      return stored;
    }

    // Fetch user email from Google
    const email = await this.getUserEmail(calendarId);

    // Store for future use
    await this.set("user_email", email);
    return email;
  }

  /**
   * Resolves "primary" calendar ID to the actual calendar ID (user's email).
   * Returns the calendarId unchanged if it's not "primary".
   */
  private async resolveCalendarId(calendarId: string): Promise<string> {
    if (calendarId !== "primary") {
      return calendarId;
    }

    // Get actual calendar ID from Google
    const api = await this.getApi(calendarId);
    const calendar = (await api.call(
      "GET",
      `https://www.googleapis.com/calendar/v3/calendars/primary`
    )) as { id: string };

    return calendar.id;
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
      }>;
    };

    return data.items.map((item) => ({
      id: item.id,
      name: item.summary,
      description: item.description || null,
      primary: item.primary || false,
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

    // Check if sync is already in progress for this calendar
    const syncInProgress = await this.get<boolean>(
      `sync_lock_${resolvedCalendarId}`
    );
    if (syncInProgress) {
      return;
    }

    // Set sync lock
    await this.set(`sync_lock_${resolvedCalendarId}`, true);

    // Setup webhook for this calendar
    await this.setupCalendarWatch(resolvedCalendarId);

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
    // 1. Cancel scheduled renewal task
    const renewalTask = await this.get<string>(
      `watch_renewal_task_${calendarId}`
    );
    if (renewalTask) {
      await this.cancelTask(renewalTask);
      await this.clear(`watch_renewal_task_${calendarId}`);
    }

    // 2. Stop watch via Google API (best effort)
    try {
      await this.stopCalendarWatch(calendarId);
    } catch (error) {
      console.warn(
        "Failed to stop calendar watch:",
        error instanceof Error ? error.message : error
      );
    }

    // 3. Clear sync-related storage
    await this.clear(`calendar_watch_${calendarId}`);
    await this.clear(`sync_state_${calendarId}`);
    await this.clear(`sync_lock_${calendarId}`);
    await this.clear(`auth_token_${calendarId}`);
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
    const watchData = await this.get<any>(`calendar_watch_${calendarId}`);
    if (!watchData) {
      return;
    }

    const api = existingApi ?? (await this.getApi(calendarId));

    // Call Google Calendar API to stop the watch
    // https://developers.google.com/calendar/api/v3/reference/channels/stop
    await api.call(
      "POST",
      "https://www.googleapis.com/calendar/v3/channels/stop",
      undefined,
      {
        id: watchData.watchId,
        resourceId: watchData.resourceId,
      }
    );
  }

  /**
   * Schedule proactive renewal of a calendar watch 24 hours before expiry.
   * Creates a callback to renewCalendarWatch and schedules it using the Tasks tool.
   *
   * @private
   */
  private async scheduleWatchRenewal(calendarId: string): Promise<void> {
    const watchData = await this.get<any>(`calendar_watch_${calendarId}`);
    if (!watchData?.expiry) {
      console.warn(`No watch data found for calendar ${calendarId}`);
      return;
    }

    // Calculate renewal time: 24 hours before expiry
    const expiry = new Date(watchData.expiry);
    const renewalTime = new Date(expiry.getTime() - 24 * 60 * 60 * 1000);

    // Don't schedule if already past renewal time (edge case)
    if (renewalTime <= new Date()) {
      await this.renewCalendarWatch(calendarId);
      return;
    }

    // Create callback for renewal (only pass calendarId - serializable!)
    const renewalCallback = await this.callback(
      this.renewCalendarWatch,
      calendarId
    );

    // Schedule renewal task
    const taskToken = await this.runTask(renewalCallback, {
      runAt: renewalTime,
    });

    // Store task token for cleanup
    if (taskToken) {
      await this.set(`watch_renewal_task_${calendarId}`, taskToken);
    }
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
      // Get existing watch data
      const oldWatchData = await this.get<any>(`calendar_watch_${calendarId}`);
      if (!oldWatchData) {
        console.warn(
          `No watch data found for calendar ${calendarId}, skipping renewal`
        );
        return;
      }

      // Stop the old watch (best effort - don't fail if this errors)
      try {
        await this.stopCalendarWatch(calendarId);
      } catch (error) {
        console.warn(`Failed to stop old watch for ${calendarId}:`, error);
      }

      // Create new watch
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

    // Check if webhook URL is localhost
    if (URL.parse(webhookUrl)?.hostname === "localhost") {
      return;
    }

    try {
      const api = await this.getApi(calendarId);

      // Setup watch for calendar
      const watchId = crypto.randomUUID();
      const secret = crypto.randomUUID();

      const watchData = (await api.call(
        "POST",
        `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events/watch`,
        undefined,
        {
          id: watchId,
          type: "web_hook",
          address: webhookUrl,
          token: new URLSearchParams({ secret }).toString(),
        }
      )) as { expiration: string; resourceId: string };

      await this.set(`calendar_watch_${calendarId}`, {
        watchId,
        resourceId: watchData.resourceId,
        secret,
        calendarId,
        expiry: new Date(parseInt(watchData.expiration)),
      });

      // Schedule proactive renewal 24 hours before expiry
      await this.scheduleWatchRenewal(calendarId);
    } catch (error) {
      console.error(
        `Failed to setup calendar watch for calendar ${calendarId}:`,
        error
      );
      throw error;
    }
  }

  async syncBatch(
    batchNumber: number,
    mode: "full" | "incremental",
    calendarId: string,
    initialSync: boolean
  ): Promise<void> {
    try {
      // Ensure we have the user's identity for RSVP tagging
      if (batchNumber === 1) {
        await this.ensureUserIdentity(calendarId);
      }

      const state = await this.get<SyncState>(`sync_state_${calendarId}`);
      if (!state) {
        const syncLock = await this.get<boolean>(`sync_lock_${calendarId}`);
        if (!syncLock) {
          // Both state and lock are cleared - sync completed normally, stale callback
        } else {
          console.warn(
            `No sync state found for calendar ${calendarId}, sync may have been superseded`
          );
          await this.clear(`sync_lock_${calendarId}`);
        }
        return;
      }

      // Convert date strings back to Date objects after deserialization
      if (state.min && typeof state.min === "string") {
        state.min = new Date(state.min);
      }
      if (state.max && typeof state.max === "string") {
        state.max = new Date(state.max);
      }

      const api = await this.getApi(calendarId);
      const result = await syncGoogleCalendar(api, calendarId, state);

      if (result.events.length > 0) {
        await this.processCalendarEvents(
          result.events,
          calendarId,
          initialSync
        );
      }

      await this.set(`sync_state_${calendarId}`, result.state);

      if (result.state.more) {
        const syncCallback = await this.callback(
          this.syncBatch,
          batchNumber + 1,
          mode,
          calendarId,
          initialSync
        );
        await this.runTask(syncCallback);
      } else {
        // Persist sync token for future incremental syncs
        if (result.state.state) {
          await this.set(`last_sync_token_${calendarId}`, result.state.state);
        }

        // Quick pass done: transition to full pass without releasing the
        // lock. The full pass walks the historical range (timeMin = 2y ago)
        // and picks up long-running recurring masters that timeMin = now
        // excluded. Any exception instances the quick pass buffered into
        // pending_occ: are carried across; they're only cleared when the
        // full pass completes below.
        if (state.phase === "quick") {
          const historyMin = new Date();
          historyMin.setFullYear(historyMin.getFullYear() - 2);
          historyMin.setMonth(0, 1);
          historyMin.setHours(0, 0, 0, 0);
          const fullState: SyncState = {
            calendarId,
            min: historyMin,
            max: null,
            sequence: 1,
            phase: "full",
          };
          await this.set(`sync_state_${calendarId}`, fullState);
          const fullCallback = await this.callback(
            this.syncBatch,
            1,
            mode,
            calendarId,
            initialSync
          );
          await this.runTask(fullCallback);
          return;
        }

        if (mode === "full") {
          // Discard buffered occurrences whose masters never appeared
          // (e.g. instances of cancelled/deleted recurring events)
          const pendingKeys = await this.tools.store.list("pending_occ:");
          for (const key of pendingKeys) {
            await this.clear(key);
          }

          await this.clear(`sync_state_${calendarId}`);
        }
        // Always clear lock when sync completes (no more batches)
        await this.clear(`sync_lock_${calendarId}`);
      }
    } catch (error) {
      console.error(
        `Error in sync batch ${batchNumber} for calendar ${calendarId}:`,
        error
      );

      // Clear lock and state so future syncs aren't permanently blocked
      await this.clear(`sync_lock_${calendarId}`);
      await this.clear(`sync_state_${calendarId}`);

      throw error;
    }
  }

  private async processCalendarEvents(
    events: GoogleEvent[],
    calendarId: string,
    initialSync: boolean
  ): Promise<void> {
    // Coalesce everything keyed by canonical URL so a master + any number of
    // its exception instances (and multiple exceptions of the same series
    // landing in the same page) collapse into a single NewLinkWithNotes. The
    // final saveLinks call makes one RPC for the entire page.
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
      // Merge occurrences and notes. Prefer the fuller entry (master) when
      // only one side carries the series-level fields (schedules, title...).
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
        existing.status = link.status ?? existing.status;
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

    for (const event of events) {
      try {
        // Extract contacts from organizer and attendees
        let validAttendees: typeof event.attendees = [];

        // Prepare author contact (organizer) - will be passed directly as NewContact
        let authorContact: NewContact | undefined = undefined;
        if (event.organizer?.email) {
          authorContact = {
            email: event.organizer.email,
            name: event.organizer.displayName,
          };
        }

        // Prepare attendee contacts for tags
        if (event.attendees && event.attendees.length > 0) {
          // Filter to get only valid attendees (with email, not resources)
          validAttendees = event.attendees.filter(
            (att) => att.email && !att.resource
          );
        }

        // Check if this is a recurring event instance (exception)
        if (event.recurringEventId && event.originalStartTime) {
          const instanceLink = await this.prepareEventInstance(
            event,
            calendarId,
            initialSync
          );
          if (instanceLink) addLink(instanceLink as LinkWithSource);
        } else {
          // Regular or master recurring event
          const activityData = transformGoogleEvent(event, calendarId);

          // Handle cancelled events
          if (event.status === "cancelled") {
            // On initial sync, skip creating activities for already-cancelled events
            if (initialSync) {
              continue;
            }
            // Canonical source for this event (required for upsert).
            // iCalUID is shared across all attendees' copies of a meeting,
            // so using it converges cross-user threads for the same event.
            const canonicalUrl = `google-calendar:${event.iCalUID ?? event.id}`;

            // Create cancellation note
            const cancelledBy =
              event.organizer?.displayName || event.organizer?.email;
            const cancelNote = {
              key: "cancellation" as const,
              content: cancelledBy
                ? `${cancelledBy} cancelled this event.`
                : "This event was cancelled.",
              contentType: "text" as const,
              created: event.updated ? new Date(event.updated) : new Date(),
            };

            // Convert to link with cancellation note
            const link: NewLinkWithNotes = {
              source: canonicalUrl,
              created: event.created ? new Date(event.created) : undefined,
              type: "event",
              title: activityData.title || undefined,
              status: "Cancelled",
              preview: "Cancelled",
              meta: activityData.meta ?? null,
              notes: [cancelNote],
              schedules: [
                {
                  start: event.start?.dateTime
                    ? new Date(event.start.dateTime)
                    : event.start?.date
                    ? event.start.date
                    : new Date(),
                  archived: true,
                },
              ],
              ...(initialSync ? { unread: false } : {}), // false for initial sync, omit for incremental updates
              ...(initialSync ? { archived: false } : {}), // unarchive on initial sync only
            };

            // Inject sync metadata for the parent to identify the source
            link.channelId = calendarId;
            link.meta = {
              ...link.meta,
              syncProvider: "google",
              syncableId: calendarId,
            };

            addLink(link as LinkWithSource);
            continue;
          }

          // Add contacts to the base schedule so client-generated recurring
          // occurrences inherit attendee data (needed for RSVP buttons).
          // Per-occurrence overrides with their own contacts take precedence.
          if (
            validAttendees.length > 0 &&
            activityData.schedules?.[0]
          ) {
            const contacts: NewScheduleContact[] = validAttendees.map(
              (attendee) => ({
                contact: {
                  email: attendee.email!,
                  name: attendee.displayName,
                },
                status:
                  attendee.responseStatus === "accepted"
                    ? ("attend" as const)
                    : attendee.responseStatus === "declined"
                    ? ("skip" as const)
                    : null,
                role: attendee.organizer
                  ? ("organizer" as const)
                  : attendee.optional
                  ? ("optional" as const)
                  : ("required" as const),
              })
            );
            activityData.schedules[0].contacts = contacts;
          }

          // Build actions array for videoconferencing and calendar links
          const actions: Action[] = [];
          const seenUrls = new Set<string>();

          // Extract all conferencing links (Zoom, Teams, Webex, etc.)
          const conferencingLinks = extractConferencingLinks(event);
          for (const link of conferencingLinks) {
            if (!seenUrls.has(link.url)) {
              seenUrls.add(link.url);
              actions.push({
                type: ActionType.conferencing,
                url: link.url,
                provider: link.provider,
              });
            }
          }

          // Add Google Meet link from hangoutLink if not already added
          if (event.hangoutLink && !seenUrls.has(event.hangoutLink)) {
            seenUrls.add(event.hangoutLink);
            actions.push({
              type: ActionType.conferencing,
              url: event.hangoutLink,
              provider: ConferencingProvider.googleMeet,
            });
          }

          // Add calendar link
          if (event.htmlLink) {
            actions.push({
              type: ActionType.external,
              title: "View in Calendar",
              url: event.htmlLink,
            });
          }

          // Prepare description content
          const descriptionValue =
            activityData.meta?.description || event.description;
          const description =
            typeof descriptionValue === "string" ? descriptionValue : null;
          const hasDescription = description && description.trim().length > 0;
          const hasActions = actions.length > 0;

          if (!activityData.type) {
            continue;
          }

          // Canonical source for this event (required for upsert).
          // iCalUID is shared across all attendees' copies of a meeting,
          // so using it converges cross-user threads for the same event.
          const canonicalUrl = `google-calendar:${event.iCalUID ?? event.id}`;

          // Build description note if available
          const descriptionNote = hasDescription
            ? {
                key: "description",
                content: description,
                contentType:
                  description && containsHtml(description)
                    ? ("html" as const)
                    : ("text" as const),
                created: event.created ? new Date(event.created) : undefined,
                ...(authorContact ? { author: authorContact } : {}),
              }
            : null;

          // Build attendee contacts for link-level access control
          const attendeeMentions: NewContact[] = [];
          if (authorContact) attendeeMentions.push(authorContact);
          for (const att of validAttendees) {
            if (att.email) {
              attendeeMentions.push({
                email: att.email,
                name: att.displayName,
              });
            }
          }

          const notes = descriptionNote ? [descriptionNote] : [];

          const link: NewLinkWithNotes = {
            source: canonicalUrl,
            created: event.created ? new Date(event.created) : undefined,
            type: "event",
            status:
              event.status === "confirmed"
                ? "Confirmed"
                : event.status === "tentative"
                ? "Tentative"
                : undefined,
            title: activityData.title || "",
            access: "private",
            accessContacts: attendeeMentions,
            author: authorContact,
            meta: activityData.meta ?? null,
            actions: hasActions ? actions : undefined,
            sourceUrl: event.htmlLink ?? null,
            notes,
            preview: hasDescription ? description : null,
            schedules: activityData.schedules,
            scheduleOccurrences: activityData.scheduleOccurrences,
            ...(initialSync ? { unread: false } : {}), // false for initial sync, omit for incremental updates
            ...(initialSync ? { archived: false } : {}), // unarchive on initial sync only
          };

          // Inject sync metadata for the parent to identify the source
          link.channelId = calendarId;
          link.meta = {
            ...link.meta,
            syncProvider: "google",
            syncableId: calendarId,
          };

          // Merge any buffered occurrences that arrived before this master
          // event. Each pending occurrence is stored under its own key
          // (pending_occ:<master>:<occurrenceIso>) so instance buffering is
          // O(1) per instance instead of rewriting a growing list — see
          // prepareEventInstance.
          const pendingPrefix = `pending_occ:${canonicalUrl}:`;
          const pendingKeys = await this.tools.store.list(pendingPrefix);
          if (pendingKeys.length > 0) {
            const merged: NewScheduleOccurrence[] = [
              ...(link.scheduleOccurrences || []),
            ];
            for (const key of pendingKeys) {
              const pending = await this.get<NewScheduleOccurrence>(key);
              if (pending) merged.push(pending);
              await this.clear(key);
            }
            link.scheduleOccurrences = merged;
          }

          addLink(link as LinkWithSource);
        }
      } catch (error) {
        console.error(`Failed to process event ${event.id}:`, error);
        // Continue processing other events
      }
    }

    // Single batched save for the whole page. Collapses what used to be
    // one saveLink RPC per event (and one per exception instance on heavy
    // recurring meetings) into a single cross-runtime call.
    const batch = Array.from(linksBySource.values());
    if (batch.length > 0) {
      // Enrich attendee/organizer contacts with names + avatars from the
      // user's Google Contacts and "other contacts". Calendar already
      // merges GoogleContacts.SCOPES into its scopes, so the People API
      // is reachable without a separate connector install.
      try {
        const token = await this.tools.integrations.get(calendarId);
        if (token) {
          await enrichLinkContactsFromGoogle(batch, token.token, token.scopes);
        }
      } catch (err) {
        // Best-effort — Gravatar fallback in the client still covers
        // anyone the People API doesn't return.
        console.warn(
          "Failed to enrich Google Calendar contacts (non-blocking):",
          err
        );
      }

      await this.tools.integrations.saveLinks(batch);
    }
  }

  /**
   * Transform a recurring event instance (occurrence) into either an
   * occurrence-only {@link NewLinkWithNotes} (for the caller's batched
   * saveLinks), or `null` when the occurrence is instead buffered to
   * `pending_occ:` storage for cross-batch merging. Never saves directly.
   */
  private async prepareEventInstance(
    event: GoogleEvent,
    calendarId: string,
    initialSync: boolean
  ): Promise<NewLinkWithNotes | null> {
    const originalStartTime =
      event.originalStartTime?.dateTime || event.originalStartTime?.date;
    if (!originalStartTime) {
      console.warn(`No original start time for instance: ${event.id}`);
      return null;
    }

    // The recurring event ID points to the master thread
    if (!event.recurringEventId) {
      console.warn(`No recurring event ID for instance: ${event.id}`);
      return null;
    }

    // Canonical URL for the master recurring event. All occurrences share
    // the master's iCalUID, so this produces the same source the master
    // event path uses (and converges cross-user threads for shared meetings).
    const masterCanonicalUrl = `google-calendar:${event.iCalUID ?? event.recurringEventId}`;

    // Transform the instance data
    const instanceData = transformGoogleEvent(event, calendarId);

    // Handle cancelled recurring instances via archived schedule occurrence
    if (event.status === "cancelled") {
      // Extract start from the event for the occurrence
      const start = event.start?.dateTime
        ? new Date(event.start.dateTime)
        : event.start?.date
        ? event.start.date
        : new Date(originalStartTime);

      const end = event.end?.dateTime
        ? new Date(event.end.dateTime)
        : event.end?.date
        ? event.end.date
        : null;

      const cancelledOccurrence: NewScheduleOccurrence = {
        occurrence: new Date(originalStartTime),
        start: start,
        end: end,
        archived: true,
      };

      // During initial sync, buffer the occurrence under a unique key for
      // later merging with its master. Per-occurrence keys keep each write
      // O(1); appending to a single shared list was O(N²) across batches
      // (re-serializing a growing array every instance) and blew the CF
      // worker CPU limit on calendars with many recurring exceptions.
      if (initialSync) {
        const pendingKey = `pending_occ:${masterCanonicalUrl}:${new Date(
          originalStartTime
        ).toISOString()}`;
        await this.set(pendingKey, cancelledOccurrence);
        return null;
      }

      const cancelledBy =
        event.organizer?.displayName || event.organizer?.email;
      const cancelNote = {
        key: "cancellation" as const,
        content: cancelledBy
          ? `${cancelledBy} cancelled this event.`
          : "This event was cancelled.",
        contentType: "text" as const,
        created: event.updated ? new Date(event.updated) : new Date(),
      };

      return {
        type: "event",
        title: undefined,
        source: masterCanonicalUrl,
        channelId: calendarId,
        meta: { syncProvider: "google", syncableId: calendarId },
        scheduleOccurrences: [cancelledOccurrence],
        notes: [cancelNote],
      };
    }

    // Build contacts from attendees for this occurrence
    const validAttendees =
      event.attendees?.filter((att) => att.email && !att.resource) || [];

    const contacts: NewScheduleContact[] | undefined =
      validAttendees.length > 0
        ? validAttendees.map((attendee) => ({
            contact: {
              email: attendee.email!,
              name: attendee.displayName,
            },
            status:
              attendee.responseStatus === "accepted"
                ? ("attend" as const)
                : attendee.responseStatus === "declined"
                ? ("skip" as const)
                : null,
            role: attendee.organizer
              ? ("organizer" as const)
              : attendee.optional
              ? ("optional" as const)
              : ("required" as const),
          }))
        : undefined;

    // Build schedule occurrence object
    // Always include start to ensure upsert can infer scheduling when
    // creating a new master thread. Use instanceData schedule start if available
    // (for rescheduled instances), otherwise fall back to originalStartTime.
    const instanceSchedule = instanceData.schedules?.[0];
    const occurrenceStart =
      instanceSchedule?.start ?? new Date(originalStartTime);

    const occurrence: NewScheduleOccurrence = {
      occurrence: new Date(originalStartTime),
      start: occurrenceStart,
      contacts,
      ...(initialSync ? { unread: false } : {}),
    };

    // Add end override if present on the instance
    if (instanceSchedule?.end !== undefined && instanceSchedule?.end !== null) {
      occurrence.end = instanceSchedule.end;
    }

    // During initial sync, buffer the occurrence under a unique key for
    // later merging with its master. See the cancelled branch above for why
    // per-occurrence keys replaced the single-list-append pattern.
    if (initialSync) {
      const pendingKey = `pending_occ:${masterCanonicalUrl}:${new Date(
        originalStartTime
      ).toISOString()}`;
      await this.set(pendingKey, occurrence);
      return null;
    }

    // Incremental sync: return an occurrence-only link. The caller merges
    // it with the master (if the master is in the same batch) or saves it
    // standalone (master already exists in the DB from a prior sync).
    return {
      type: "event",
      title: undefined,
      source: masterCanonicalUrl,
      channelId: calendarId,
      meta: { syncProvider: "google", syncableId: calendarId },
      scheduleOccurrences: [occurrence],
      notes: [],
    };
  }

  async onCalendarWebhook(
    request: WebhookRequest,
    calendarId: string
  ): Promise<void> {
    const channelId = request.headers["x-goog-channel-id"];
    const channelToken = request.headers["x-goog-channel-token"];

    if (!channelId || !channelToken) {
      console.warn("Google Calendar webhook missing required headers", {
        calendarId,
      });
      return;
    }

    const watchData = await this.get<any>(`calendar_watch_${calendarId}`);

    if (!watchData || watchData.watchId !== channelId) {
      console.warn("Unknown or expired webhook notification");
      return;
    }

    const params = new URLSearchParams(channelToken);
    const secret = params.get("secret");

    if (!watchData || watchData.secret !== secret) {
      console.warn("Invalid webhook secret");
      return;
    }

    // Reactive expiry check
    const expiration = new Date(watchData.expiry);
    const now = new Date();
    const hoursUntilExpiry =
      (expiration.getTime() - now.getTime()) / (1000 * 60 * 60);

    if (hoursUntilExpiry < 24) {
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
    const syncInProgress = await this.get<boolean>(`sync_lock_${calendarId}`);
    if (syncInProgress) {
      return;
    }

    const watchData = await this.get<any>(`calendar_watch_${calendarId}`);
    if (!watchData) {
      console.error("No calendar watch data found");
      return;
    }

    const syncToken = await this.get<string>(`last_sync_token_${calendarId}`);

    const incrementalState: SyncState = syncToken
      ? {
          calendarId: watchData.calendarId,
          state: syncToken,
        }
      : {
          calendarId: watchData.calendarId,
          min: new Date(Date.now() - 7 * 24 * 60 * 60 * 1000),
          sequence: 1,
        };

    await this.set(`sync_state_${calendarId}`, incrementalState);
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
   * Constructs a Google Calendar instance ID for a recurring event occurrence.
   * @param baseEventId - The recurring event ID
   * @param occurrence - The occurrence date (Date or ISO string)
   * @returns Instance ID in format: {baseEventId}_{YYYYMMDDTHHMMSSZ}
   */
  private constructInstanceId(
    baseEventId: string,
    occurrence: Date | string
  ): string {
    let occurrenceDate: Date;

    if (occurrence instanceof Date) {
      occurrenceDate = occurrence;
    } else if (typeof occurrence === "string") {
      occurrenceDate = new Date(occurrence);
    } else {
      throw new Error(`Invalid occurrence type: ${typeof occurrence}`);
    }

    // Format as YYYYMMDDTHHMMSSZ (Google Calendar instance ID format)
    const instanceDateStr = occurrenceDate
      .toISOString()
      .replace(/[-:]/g, "") // Remove dashes and colons
      .replace(/\.\d{3}/, ""); // Remove milliseconds

    return `${baseEventId}_${instanceDateStr}`;
  }

  /**
   * Sync a schedule contact RSVP change back to Google Calendar.
   * Called via actAs() which provides the actor's auth token.
   */
  async syncActorRSVP(
    token: AuthToken,
    calendarId: string,
    eventId: string,
    status: "accepted" | "declined" | "tentative" | "needsAction",
    _actorId: string
  ): Promise<void> {
    try {
      const api = new GoogleApi(token.token);
      await this.updateEventRSVPWithApi(api, calendarId, eventId, status);
    } catch (error) {
      console.error("[RSVP Sync] Failed to sync RSVP", {
        event_id: eventId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  /**
   * Called when a user changes their RSVP status in Plot.
   * Syncs the change back to Google Calendar via actAs().
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
    // Per-calendar Google event id is stored in meta.id by transformGoogleEvent.
    // We can't derive it from `source` anymore, because source uses iCalUID
    // (shared across calendars) for cross-user dedup.
    const eventId = meta?.id as string | null;

    if (!eventId || !calendarId) return;

    // Map Plot status to Google Calendar status
    const googleStatus =
      status === "attend"
        ? ("accepted" as const)
        : status === "skip"
        ? ("declined" as const)
        : ("needsAction" as const);

    await this.tools.integrations.actAs(
      AuthProvider.Google,
      actor.id,
      thread.id,
      this.syncActorRSVP,
      calendarId,
      eventId,
      googleStatus,
      actor.id as string
    );
  }

  /**
   * Update RSVP status for the authenticated user on a Google Calendar event.
   * Looks up the user's email from the calendar API to find the correct attendee.
   */
  private async updateEventRSVPWithApi(
    api: GoogleApi,
    calendarId: string,
    eventId: string,
    status: "accepted" | "declined" | "needsAction" | "tentative"
  ): Promise<void> {
    // Fetch the current event to get attendees list
    const event = (await api.call(
      "GET",
      `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events/${eventId}`
    )) as GoogleEvent | null;

    if (!event) {
      throw new Error(`Event ${eventId} not found`);
    }

    // Get the actor's email from the calendar API (their primary calendar ID)
    const calendarList = (await api.call(
      "GET",
      "https://www.googleapis.com/calendar/v3/users/me/calendarList/primary"
    )) as { id: string };
    const actorEmail = calendarList.id;

    // Find and update the actor's attendee status
    const attendees = event.attendees || [];
    const actorAttendeeIndex = attendees.findIndex(
      (att) =>
        att.self === true ||
        att.email?.toLowerCase() === actorEmail.toLowerCase()
    );

    if (actorAttendeeIndex === -1) {
      console.warn("[RSVP Sync] Actor is not an attendee of this event", {
        event_id: eventId,
      });
      return;
    }

    // Check if status already matches to avoid infinite loops
    if (attendees[actorAttendeeIndex].responseStatus === status) {
      return;
    }

    // Update the attendee's response status
    attendees[actorAttendeeIndex].responseStatus = status;

    // Update the event with the new attendees list
    await api.call(
      "PATCH",
      `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events/${eventId}`,
      undefined,
      { attendees }
    );
  }
}

export default GoogleCalendar;
