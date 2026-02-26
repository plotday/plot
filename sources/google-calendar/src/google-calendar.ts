import GoogleContacts from "@plotday/source-google-contacts";
import {
  ActionType,
  type Action,
  ConferencingProvider,
  type NewLinkWithNotes,
  type NewContact,
  type NewNote,
  Source,
  type ToolBuilder,
} from "@plotday/twister";
import type {
  NewScheduleContact,
  NewScheduleOccurrence,
} from "@plotday/twister/schedule";
import {
  type Calendar,
  type CalendarSource,
  type SyncOptions,
} from "@plotday/twister/common/calendar";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
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
 *       type: ThreadType.Action,
 *       title: "Connect Google Calendar",
 *       actions: [authLink]
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
export class GoogleCalendar
  extends Source<GoogleCalendar>
  implements CalendarSource
{
  static readonly PROVIDER = AuthProvider.Google;
  static readonly SCOPES = [
    "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    "https://www.googleapis.com/auth/calendar.events",
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations, {
        providers: [
          {
            provider: GoogleCalendar.PROVIDER,
            scopes: Integrations.MergeScopes(
              GoogleCalendar.SCOPES,
              GoogleContacts.SCOPES
            ),
            linkTypes: [{ type: "event", label: "Event", logo: "https://api.iconify.design/logos/google-calendar.svg" }],
            getChannels: this.getChannels,
            onChannelEnabled: this.onChannelEnabled,
            onChannelDisabled: this.onChannelDisabled,
          },
        ],
      }),
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
  async getChannels(_auth: Authorization, token: AuthToken): Promise<Channel[]> {
    const api = new GoogleApi(token.token);
    const calendars = await this.listCalendarsWithApi(api);
    return calendars.map((c) => ({ id: c.id, title: c.name }));
  }

  /**
   * Called when a channel calendar is enabled for syncing.
   * Auto-starts sync for the calendar.
   */
  async onChannelEnabled(channel: Channel): Promise<void> {
    // Resolve "primary" to actual calendar ID for consistent storage keys
    const resolvedCalendarId = await this.resolveCalendarId(channel.id);

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
    const now = new Date();
    const min = new Date(now.getFullYear() - 2, 0, 1);

    const initialState: SyncState = {
      calendarId: resolvedCalendarId,
      min,
      max: null,
      sequence: 1,
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
    const token = await this.tools.integrations.get(
      GoogleCalendar.PROVIDER,
      calendarId
    );

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
    } & SyncOptions,
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
        if (result.state.state && !result.state.more) {
          await this.set(`last_sync_token_${calendarId}`, result.state.state);
        }

        if (mode === "full") {
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

      throw error;
    }
  }

  private async processCalendarEvents(
    events: GoogleEvent[],
    calendarId: string,
    initialSync: boolean
  ): Promise<void> {
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
          await this.processEventInstance(
            event,
            calendarId,
            initialSync
          );
        } else {
          // Regular or master recurring event
          const activityData = transformGoogleEvent(event, calendarId);

          // Handle cancelled events
          if (event.status === "cancelled") {
            // On initial sync, skip creating activities for already-cancelled events
            if (initialSync) {
              continue;
            }
            // Canonical source for this event (required for upsert)
            const canonicalUrl = `google-calendar:${event.id}`;

            // Create cancellation note
            const cancelNote = {
              key: "cancellation" as const,
              content: "This event was cancelled.",
              contentType: "text" as const,
              created: event.updated ? new Date(event.updated) : new Date(),
            };

            // Convert to link with cancellation note
            const link: NewLinkWithNotes = {
              source: canonicalUrl,
              created: event.created ? new Date(event.created) : undefined,
              type: "event",
              title: activityData.title || "Cancelled event",
              preview: "Cancelled",
              meta: activityData.meta ?? null,
              notes: [cancelNote],
              ...(initialSync ? { unread: false } : {}), // false for initial sync, omit for incremental updates
              ...(initialSync ? { archived: false } : {}), // unarchive on initial sync only
            };

            // Inject sync metadata for the parent to identify the source
            link.meta = { ...link.meta, syncProvider: "google", syncableId: calendarId };

            // Send link - database handles upsert automatically
            await this.tools.integrations.saveLink(link);
            continue;
          }

          // For recurring events, DON'T add contacts at series level
          // Contacts (RSVPs) should be per-occurrence via the scheduleOccurrences array
          // For non-recurring events, add contacts to the schedule
          const isRecurring = !!activityData.schedules?.[0]?.recurrenceRule;
          if (validAttendees.length > 0 && !isRecurring && activityData.schedules?.[0]) {
            const contacts: NewScheduleContact[] = validAttendees.map((attendee) => ({
              contact: {
                email: attendee.email!,
                name: attendee.displayName,
              },
              status: attendee.responseStatus === "accepted" ? "attend" as const
                : attendee.responseStatus === "declined" ? "skip" as const
                : null,
              role: attendee.organizer ? "organizer" as const
                : attendee.optional ? "optional" as const
                : "required" as const,
            }));
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

          // Canonical source for this event (required for upsert)
          const canonicalUrl = `google-calendar:${event.id}`;

          // Build description note if available
          const descriptionNote = hasDescription ? {
            key: "description",
            content: description,
            contentType:
              description && containsHtml(description) ? "html" as const : "text" as const,
            created: event.created ? new Date(event.created) : new Date(),
          } : null;

          const link: NewLinkWithNotes = {
            source: canonicalUrl,
            created: event.created ? new Date(event.created) : undefined,
            type: "event",
            title: activityData.title || "",
            author: authorContact,
            meta: activityData.meta ?? null,
            actions: hasActions ? actions : undefined,
            sourceUrl: event.htmlLink ?? null,
            notes: descriptionNote ? [descriptionNote] : [],
            preview: hasDescription ? description : null,
            schedules: activityData.schedules,
            scheduleOccurrences: activityData.scheduleOccurrences,
            ...(initialSync ? { unread: false } : {}), // false for initial sync, omit for incremental updates
            ...(initialSync ? { archived: false } : {}), // unarchive on initial sync only
          };

          // Inject sync metadata for the parent to identify the source
          link.meta = { ...link.meta, syncProvider: "google", syncableId: calendarId };

          // Send link - database handles upsert automatically
          await this.tools.integrations.saveLink(link);
        }
      } catch (error) {
        console.error(`Failed to process event ${event.id}:`, error);
        // Continue processing other events
      }
    }
  }

  /**
   * Process a recurring event instance (occurrence) from Google Calendar.
   * This updates the master recurring thread with occurrence-specific data.
   */
  private async processEventInstance(
    event: GoogleEvent,
    calendarId: string,
    initialSync: boolean
  ): Promise<void> {
    const originalStartTime =
      event.originalStartTime?.dateTime || event.originalStartTime?.date;
    if (!originalStartTime) {
      console.warn(`No original start time for instance: ${event.id}`);
      return;
    }

    // The recurring event ID points to the master thread
    if (!event.recurringEventId) {
      console.warn(`No recurring event ID for instance: ${event.id}`);
      return;
    }

    // Canonical URL for the master recurring event
    const masterCanonicalUrl = `google-calendar:${calendarId}:${event.recurringEventId}`;

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

      const occurrenceUpdate: NewLinkWithNotes = {
        type: "event",
        title: "",
        source: masterCanonicalUrl,
        meta: { syncProvider: "google", syncableId: calendarId },
        scheduleOccurrences: [cancelledOccurrence],
        notes: [],
      };

      await this.tools.integrations.saveLink(occurrenceUpdate);
      return;
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
            status: attendee.responseStatus === "accepted" ? "attend" as const
              : attendee.responseStatus === "declined" ? "skip" as const
              : null,
            role: attendee.organizer ? "organizer" as const
              : attendee.optional ? "optional" as const
              : "required" as const,
          }))
        : undefined;

    // Build schedule occurrence object
    // Always include start to ensure upsert can infer scheduling when
    // creating a new master thread. Use instanceData schedule start if available
    // (for rescheduled instances), otherwise fall back to originalStartTime.
    const instanceSchedule = instanceData.schedules?.[0];
    const occurrenceStart = instanceSchedule?.start ?? new Date(originalStartTime);

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

    // Build a minimal link with source and scheduleOccurrences
    // The source saves directly via integrations.saveLink
    const occurrenceUpdate: NewLinkWithNotes = {
      type: "event",
      title: "",
      source: masterCanonicalUrl,
      meta: { syncProvider: "google", syncableId: calendarId },
      scheduleOccurrences: [occurrence],
      notes: [],
    };

    await this.tools.integrations.saveLink(occurrenceUpdate);
  }

  async onCalendarWebhook(
    request: WebhookRequest,
    calendarId: string
  ): Promise<void> {
    const channelId = request.headers["x-goog-channel-id"];
    const channelToken = request.headers["x-goog-channel-token"];

    if (!channelId || !channelToken) {
      throw new Error("Invalid webhook headers");
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
