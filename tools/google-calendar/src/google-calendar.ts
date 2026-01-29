import GoogleContacts from "@plotday/tool-google-contacts";
import {
  type Activity,
  type ActivityLink,
  ActivityLinkType,
  type ActivityOccurrence,
  ActivityType,
  type ActorId,
  ConferencingProvider,
  type NewActivityOccurrence,
  type NewActivityWithNotes,
  type NewActor,
  type NewContact,
  type NewNote,
  Serializable,
  Tag,
  Tool,
  type ToolBuilder,
} from "@plotday/twister";
import {
  type Calendar,
  type CalendarAuth,
  type CalendarTool,
  type SyncOptions,
} from "@plotday/twister/common/calendar";
import { type Callback } from "@plotday/twister/tools/callbacks";
import {
  AuthLevel,
  AuthProvider,
  type Authorization,
  Integrations,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import {
  ActivityAccess,
  ContactAccess,
  Plot,
} from "@plotday/twister/tools/plot";

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
 *     await this.plot.createActivity({
 *       type: ActivityType.Action,
 *       title: "Connect Google Calendar",
 *       links: [authLink]
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
 *   async onCalendarEvent(activity: NewActivityWithNotes, context: any) {
 *     // Process Google Calendar events
 *     await this.plot.createActivity(activity);
 *   }
 * }
 * ```
 */
export class GoogleCalendar
  extends Tool<GoogleCalendar>
  implements CalendarTool
{
  static readonly SCOPES = [
    "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    "https://www.googleapis.com/auth/calendar.events",
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: ["https://www.googleapis.com/calendar/*"],
      }),
      plot: build(Plot, {
        contact: {
          access: ContactAccess.Write,
        },
        activity: {
          access: ActivityAccess.Create,
          updated: this.onActivityUpdated,
        },
      }),
      googleContacts: build(GoogleContacts),
    };
  }

  async requestAuth<
    TArgs extends Serializable[],
    TCallback extends (auth: CalendarAuth, ...args: TArgs) => any
  >(callback: TCallback, ...extraArgs: TArgs): Promise<ActivityLink> {
    // Combine calendar and contacts scopes for single OAuth flow
    const combinedScopes = [...GoogleCalendar.SCOPES, ...GoogleContacts.SCOPES];

    // Generate opaque token for authorization
    const authToken = crypto.randomUUID();

    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );

    // Request auth and return the activity link
    return await this.tools.integrations.request(
      {
        provider: AuthProvider.Google,
        level: AuthLevel.User,
        scopes: combinedScopes,
      },
      this.onAuthSuccess,
      authToken,
      callbackToken
    );
  }

  private async getApi(authToken: string): Promise<GoogleApi> {
    const authorization = await this.get<Authorization>(
      `authorization:${authToken}`
    );
    if (!authorization) {
      throw new Error("Authorization no longer available");
    }

    const token = await this.tools.integrations.get(authorization);
    if (!token) {
      throw new Error("Authorization no longer available");
    }

    return new GoogleApi(token.token);
  }

  private async getUserEmail(authToken: string): Promise<string> {
    const api = await this.getApi(authToken);

    // Use the Calendar API's primary calendar to get the email
    const calendarList = (await api.call(
      "GET",
      "https://www.googleapis.com/calendar/v3/users/me/calendarList/primary"
    )) as { id: string };

    return calendarList.id; // The primary calendar ID is the user's email
  }

  private async ensureUserIdentity(authToken: string): Promise<string> {
    // Check if we already have the user email stored
    const stored = await this.get<string>("user_email");
    if (stored) {
      return stored;
    }

    // Fetch user email from Google
    const email = await this.getUserEmail(authToken);

    // Store for future use
    await this.set("user_email", email);
    return email;
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

  async startSync<
    TArgs extends Serializable[],
    TCallback extends (activity: NewActivityWithNotes, ...args: TArgs) => any
  >(
    options: {
      authToken: string;
      calendarId: string;
    } & SyncOptions,
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<void> {
    const { authToken, calendarId, timeMin, timeMax } = options;

    // Check if sync is already in progress for this calendar
    const syncInProgress = await this.get<boolean>(`sync_lock_${calendarId}`);
    if (syncInProgress) {
      return;
    }

    // Set sync lock
    await this.set(`sync_lock_${calendarId}`, true);

    // Create callback token for parent
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );
    await this.set("event_callback_token", callbackToken);

    // Store auth token for calendar for later RSVP updates
    await this.set(`auth_token_${calendarId}`, authToken);

    // Setup webhook for this calendar
    await this.setupCalendarWatch(authToken, calendarId, authToken);

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

    const initialState: SyncState = {
      calendarId,
      min,
      max,
      sequence: 1,
    };

    await this.set(`sync_state_${calendarId}`, initialState);

    // Start sync batch using run tool for long-running operation
    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "full",
      authToken,
      calendarId,
      true // initialSync = true for initial sync
    );
    await this.runTask(syncCallback);
  }

  async stopSync(_authToken: string, calendarId: string): Promise<void> {
    // 1. Cancel scheduled renewal task
    const renewalTask = await this.get<string>(
      `watch_renewal_task_${calendarId}`
    );
    if (renewalTask) {
      await this.cancelTask(renewalTask);
      await this.clear(`watch_renewal_task_${calendarId}`);
    }

    // 2. Stop watch via Google API
    const authToken = await this.get<string>(`auth_token_${calendarId}`);
    if (authToken) {
      try {
        await this.stopCalendarWatch(authToken, calendarId);
      } catch (error) {
        console.error("Failed to stop calendar watch:", error);
        // Continue with cleanup even if API call fails
      }
    }

    // 3. Clear all storage
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
    authToken: string,
    calendarId: string
  ): Promise<void> {
    const watchData = await this.get<any>(`calendar_watch_${calendarId}`);
    if (!watchData) {
      return;
    }

    const api = await this.getApi(authToken);

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
      console.log(
        `Watch for ${calendarId} expires soon, renewing immediately`
      );
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

    console.log(
      `Scheduled watch renewal for ${calendarId} at ${renewalTime.toISOString()}`
    );
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

      // Get auth token
      const authToken = await this.get<string>(`auth_token_${calendarId}`);
      if (!authToken) {
        console.error(
          `No auth token found for calendar ${calendarId}, cannot renew watch`
        );
        return;
      }

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
        await this.stopCalendarWatch(authToken, calendarId);
      } catch (error) {
        console.warn(`Failed to stop old watch for ${calendarId}:`, error);
        // Continue with renewal anyway
      }

      // Create new watch (reuses existing webhook URL and callback)
      await this.setupCalendarWatch(authToken, calendarId, authToken);

    } catch (error) {
      console.error(`Failed to renew watch for calendar ${calendarId}:`, error);
      // Don't throw - let reactive checking handle it as fallback
    }
  }

  private async setupCalendarWatch(
    authToken: string,
    calendarId: string,
    opaqueAuthToken: string
  ): Promise<void> {
    const webhookUrl = await this.tools.network.createWebhook(
      {},
      this.onCalendarWebhook,
      calendarId,
      opaqueAuthToken
    );

    // Check if webhook URL is localhost
    if (URL.parse(webhookUrl)?.hostname === "localhost") {
      return;
    }

    try {
      const api = await this.getApi(authToken);

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

      console.log(
        `Successfully setup calendar watch for ${calendarId}, expires: ${new Date(parseInt(watchData.expiration)).toISOString()}`
      );
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
    authToken: string,
    calendarId: string,
    initialSync: boolean
  ): Promise<void> {
    try {
      // Ensure we have the user's identity for RSVP tagging
      if (batchNumber === 1) {
        await this.ensureUserIdentity(authToken);
      }

      const state = await this.get<SyncState>(`sync_state_${calendarId}`);
      if (!state) {
        // Check if sync lock is also cleared - if so, sync completed normally
        const syncLock = await this.get<boolean>(`sync_lock_${calendarId}`);
        if (!syncLock) {
          // Both state and lock are cleared - sync completed normally, this is a stale callback
            } else {
          // State missing but lock still set - sync may have been superseded
          console.warn(`No sync state found for calendar ${calendarId}, sync may have been superseded`);
          await this.clear(`sync_lock_${calendarId}`);
        }
        return;
      }

      // Convert date strings back to Date objects after deserialization
      if (state.min && typeof state.min === "string") {
        state.min = new Date(state.min);
      }

      const api = await this.getApi(authToken);
      const result = await syncGoogleCalendar(api, calendarId, state);

      if (result.events.length > 0) {
        await this.processCalendarEvents(
          result.events,
          calendarId,
          initialSync
        );
        console.log(
          `Synced ${result.events.length} events in batch ${batchNumber} for calendar ${calendarId}`
        );
      }

      await this.set(`sync_state_${calendarId}`, result.state);

      if (result.state.more) {
        const syncCallback = await this.callback(
          this.syncBatch,
          batchNumber + 1,
          mode,
          authToken,
          calendarId,
          initialSync // Pass through the initialSync boolean
        );
        await this.runTask(syncCallback);
      } else {
        console.log(
          `Google Calendar ${mode} sync completed after ${batchNumber} batches for calendar ${calendarId}`
        );

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
    // Hoist callback token retrieval outside loop - saves N-1 subrequests
    const callbackToken = await this.get<Callback>("event_callback_token");
    if (!callbackToken) {
      console.warn("No callback token found, skipping event processing");
      return;
    }

    // Get user email for RSVP tagging
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
          await this.processEventInstance(event, calendarId, initialSync, callbackToken);
        } else {
          // Regular or master recurring event
          const activityData = transformGoogleEvent(event, calendarId);

          // Handle cancelled events
          if (event.status === "cancelled") {
            // Canonical URL for this event (required for upsert)
            const canonicalUrl =
              event.htmlLink || `google-calendar:${calendarId}:${event.id}`;

            // Create cancellation note
            const cancelNote: NewNote = {
              activity: { source: canonicalUrl },
              key: "cancellation",
              content: "This event was cancelled.",
              contentType: "text",
              created: new Date(),
            };

            // Convert to Note type with blocked tag and cancellation note
            const activity: NewActivityWithNotes = {
              source: canonicalUrl,
              type: ActivityType.Note,
              title: activityData.title || "",
              start: activityData.start || null,
              end: activityData.end || null,
              meta: activityData.meta ?? null,
              tags: {
                [Tag.Blocked]: [], // Toggle tag, empty actor array
              },
              notes: [cancelNote],
              // unread is automatically set by adding a note
            };

            // Send activity - database handles upsert automatically
            await this.tools.callbacks.run(callbackToken, activity);
            continue;
          }

          // For recurring events, DON'T add tags at series level
          // Tags (RSVPs) should be per-occurrence via the occurrences array
          // For non-recurring events, add tags normally
          let tags: Partial<Record<Tag, NewActor[]>> | null = null;
          if (validAttendees.length > 0 && !activityData.recurrenceRule) {
            const attendTags: NewActor[] = [];
            const skipTags: NewActor[] = [];
            const undecidedTags: NewActor[] = [];

            // Iterate through valid attendees and group by response status
            validAttendees.forEach((attendee) => {
              const newActor: NewActor = {
                email: attendee.email!,
                name: attendee.displayName,
              };

              if (attendee.responseStatus === "accepted") {
                attendTags.push(newActor);
              } else if (attendee.responseStatus === "declined") {
                skipTags.push(newActor);
              } else if (
                attendee.responseStatus === "tentative" ||
                attendee.responseStatus === "needsAction"
              ) {
                undecidedTags.push(newActor);
              }
            });

            // Only set tags if we have at least one
            if (
              attendTags.length > 0 ||
              skipTags.length > 0 ||
              undecidedTags.length > 0
            ) {
              tags = {};
              if (attendTags.length > 0) tags[Tag.Attend] = attendTags;
              if (skipTags.length > 0) tags[Tag.Skip] = skipTags;
              if (undecidedTags.length > 0) tags[Tag.Undecided] = undecidedTags;
            }
          }

          // Build links array for videoconferencing and calendar links
          const links: ActivityLink[] = [];
          const seenUrls = new Set<string>();

          // Extract all conferencing links (Zoom, Teams, Webex, etc.)
          const conferencingLinks = extractConferencingLinks(event);
          for (const link of conferencingLinks) {
            if (!seenUrls.has(link.url)) {
              seenUrls.add(link.url);
              links.push({
                type: ActivityLinkType.conferencing,
                url: link.url,
                provider: link.provider,
              });
            }
          }

          // Add Google Meet link from hangoutLink if not already added
          if (event.hangoutLink && !seenUrls.has(event.hangoutLink)) {
            seenUrls.add(event.hangoutLink);
            links.push({
              type: ActivityLinkType.conferencing,
              url: event.hangoutLink,
              provider: ConferencingProvider.googleMeet,
            });
          }

          // Add calendar link
          if (event.htmlLink) {
            links.push({
              type: ActivityLinkType.external,
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
          const hasLinks = links.length > 0;

          if (!activityData.type) {
            continue;
          }

          // Canonical URL for this event (required for upsert)
          const canonicalUrl =
            event.htmlLink || `google-calendar:${calendarId}:${event.id}`;

          // Create note with description and/or links
          const notes: NewNote[] = [];
          if (hasDescription || hasLinks) {
            notes.push({
              activity: { source: canonicalUrl },
              key: "description",
              content: hasDescription ? description : null,
              links: hasLinks ? links : null,
              contentType:
                description && containsHtml(description) ? "html" : "text",
              created: event.created ? new Date(event.created) : new Date(),
            });
          }

          const activity: NewActivityWithNotes = {
            source: canonicalUrl,
            type: activityData.type,
            created: event.created ? new Date(event.created) : undefined,
            start: activityData.start || null,
            end: activityData.end || null,
            recurrenceUntil: activityData.recurrenceUntil || null,
            recurrenceCount: activityData.recurrenceCount || null,
            done: null,
            title: activityData.title || "",
            author: authorContact,
            recurrenceRule: activityData.recurrenceRule || null,
            recurrenceExdates: activityData.recurrenceExdates || null,
            meta: activityData.meta ?? null,
            tags: tags || undefined,
            notes,
            preview: hasDescription ? description : null,
            unread: !initialSync, // false for initial sync, true for incremental updates
            ...(initialSync ? { archived: false } : {}), // unarchive on initial sync only
          };

          // Send activity - database handles upsert automatically
          await this.tools.callbacks.run(callbackToken, activity);
        }
      } catch (error) {
        console.error(`Failed to process event ${event.id}:`, error);
        // Continue processing other events
      }
    }
  }

  /**
   * Process a recurring event instance (occurrence) from Google Calendar.
   * This updates the master recurring activity with occurrence-specific data.
   */
  private async processEventInstance(
    event: GoogleEvent,
    calendarId: string,
    initialSync: boolean,
    callbackToken: Callback
  ): Promise<void> {
    const originalStartTime =
      event.originalStartTime?.dateTime || event.originalStartTime?.date;
    if (!originalStartTime) {
      console.warn(`No original start time for instance: ${event.id}`);
      return;
    }

    // The recurring event ID points to the master activity
    if (!event.recurringEventId) {
      console.warn(`No recurring event ID for instance: ${event.id}`);
      return;
    }

    // Canonical URL for the master recurring event
    const masterCanonicalUrl = `google-calendar:${calendarId}:${event.recurringEventId}`;

    // Transform the instance data
    const instanceData = transformGoogleEvent(event, calendarId);

    // Handle cancelled recurring instances by archiving the occurrence
    if (event.status === "cancelled") {
      const occurrence: Omit<NewActivityOccurrence, "activity"> = {
        occurrence: new Date(originalStartTime),
        start: new Date(originalStartTime),
        archived: true,
      };

      const occurrenceUpdate = {
        type: ActivityType.Event,
        source: masterCanonicalUrl,
        occurrences: [occurrence],
      };

      await this.tools.callbacks.run(callbackToken, occurrenceUpdate);
      return;
    }

    // Determine RSVP status for attendees
    const validAttendees =
      event.attendees?.filter((att) => att.email && !att.resource) || [];

    let tags: Partial<Record<Tag, import("@plotday/twister").NewActor[]>> = {};
    if (validAttendees.length > 0) {
      const attendTags: import("@plotday/twister").NewActor[] = [];
      const skipTags: import("@plotday/twister").NewActor[] = [];
      const undecidedTags: import("@plotday/twister").NewActor[] = [];

      validAttendees.forEach((attendee) => {
        const newActor: import("@plotday/twister").NewActor = {
          email: attendee.email!,
          name: attendee.displayName,
        };

        if (attendee.responseStatus === "accepted") {
          attendTags.push(newActor);
        } else if (attendee.responseStatus === "declined") {
          skipTags.push(newActor);
        } else if (
          attendee.responseStatus === "tentative" ||
          attendee.responseStatus === "needsAction"
        ) {
          undecidedTags.push(newActor);
        }
      });

      if (attendTags.length > 0) tags[Tag.Attend] = attendTags;
      if (skipTags.length > 0) tags[Tag.Skip] = skipTags;
      if (undecidedTags.length > 0) tags[Tag.Undecided] = undecidedTags;
    }

    // Build occurrence object
    // Always include start to ensure upsert_activity can infer scheduling when
    // creating a new master activity. Use instanceData.start if available (for
    // rescheduled instances), otherwise fall back to originalStartTime.
    const occurrenceStart = instanceData.start ?? new Date(originalStartTime);

    const occurrence: Omit<NewActivityOccurrence, "activity"> = {
      occurrence: new Date(originalStartTime),
      start: occurrenceStart,
      tags: Object.keys(tags).length > 0 ? tags : undefined,
      unread: !initialSync,
    };

    // Add additional field overrides if present
    if (instanceData.end !== undefined && instanceData.end !== null) {
      occurrence.end = instanceData.end;
    }
    if (instanceData.title) occurrence.title = instanceData.title;
    if (instanceData.meta) occurrence.meta = instanceData.meta;

    // Send occurrence data to the twist via callback
    // The twist will decide whether to create or update the master activity

    // Build a minimal NewActivity with source and occurrences
    // The twist's createActivity will upsert the master activity
    const occurrenceUpdate = {
      type: ActivityType.Event,
      source: masterCanonicalUrl,
      occurrences: [occurrence],
    };

    await this.tools.callbacks.run(callbackToken, occurrenceUpdate);
  }

  async onCalendarWebhook(
    request: WebhookRequest,
    calendarId: string,
    authToken: string
  ): Promise<void> {
    // Validate webhook authenticity
    // Headers are normalized to lowercase by HTTP standards
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

    // Reactive expiry check (backup for missed scheduled renewal)
    const expiration = new Date(watchData.expiry);
    const now = new Date();
    const hoursUntilExpiry =
      (expiration.getTime() - now.getTime()) / (1000 * 60 * 60);

    if (hoursUntilExpiry < 24) {
      console.log(
        `Watch for ${calendarId} expires in ${hoursUntilExpiry.toFixed(
          1
        )} hours, renewing...`
      );
      // Don't await - let renewal happen async (don't block webhook)
      this.renewCalendarWatch(calendarId).catch((error) => {
        console.error(
          `Failed to reactively renew watch for ${calendarId}:`,
          error
        );
      });
    }

    // Trigger incremental sync
    await this.startIncrementalSync(calendarId, authToken);
  }

  private async startIncrementalSync(
    calendarId: string,
    authToken: string
  ): Promise<void> {
    // Check if initial sync is still in progress
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
          // No stored sync token - fall back to recent time window
          calendarId: watchData.calendarId,
          min: new Date(Date.now() - 7 * 24 * 60 * 60 * 1000), // Last 7 days
          sequence: 1,
        };

    await this.set(`sync_state_${calendarId}`, incrementalState);
    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "incremental",
      authToken,
      calendarId,
      false // initialSync = false for incremental updates
    );
    await this.runTask(syncCallback);
  }

  async onAuthSuccess(
    authResult: Authorization,
    authToken: string,
    callback: Callback
  ): Promise<void> {
    // Store the actual auth token using opaque token as key
    await this.set(`authorization:${authToken}`, authResult);

    // Trigger contacts sync with the same authorization
    // This happens automatically when calendar auth succeeds
    try {
      // Retrieve the actual auth token to pass to contacts
      const token = await this.tools.integrations.get(authResult);
      if (token) {
        await this.tools.googleContacts.syncWithAuth(
          authResult,
          token,
          this.onContactsSynced
        );
      } else {
        console.error("Failed to retrieve auth token for contacts sync");
      }
    } catch (error) {
      // Log error but don't fail calendar auth
      console.error("Failed to start contacts sync:", error);
    }

    const authSuccessResult: CalendarAuth = {
      authToken,
    };

    await this.run(callback, authSuccessResult);

    // Clean up the callback token
    await this.clear(`auth_callback_token:${authToken}`);
  }

  /**
   * Callback invoked when contacts are synced from Google Contacts.
   * Adds the synced contacts to Plot for enriching calendar event attendees.
   */
  async onContactsSynced(contacts: NewContact[]): Promise<void> {
    if (contacts.length === 0) {
      return;
    }

    try {
      await this.tools.plot.addContacts(contacts);
    } catch (error) {
      console.error("Failed to add contacts to Plot:", error);
    }
  }

  async onActivityUpdated(
    activity: Activity,
    changes: {
      tagsAdded: Record<Tag, ActorId[]>;
      tagsRemoved: Record<Tag, ActorId[]>;
      occurrence?: ActivityOccurrence;
    }
  ): Promise<void> {
    // Only process calendar events
    const source = activity.source;
    if (
      !source ||
      typeof source !== "string" ||
      !source.startsWith("google-calendar:")
    ) {
      return;
    }

    // Check if RSVP tags changed
    const attendChanged =
      Tag.Attend in changes.tagsAdded || Tag.Attend in changes.tagsRemoved;
    const skipChanged =
      Tag.Skip in changes.tagsAdded || Tag.Skip in changes.tagsRemoved;
    const undecidedChanged =
      Tag.Undecided in changes.tagsAdded ||
      Tag.Undecided in changes.tagsRemoved;

    if (!attendChanged && !skipChanged && !undecidedChanged) {
      return; // No RSVP-related tag changes
    }

    // Determine new RSVP status based on current tags
    const hasAttend =
      activity.tags?.[Tag.Attend] && activity.tags[Tag.Attend].length > 0;
    const hasSkip =
      activity.tags?.[Tag.Skip] && activity.tags[Tag.Skip].length > 0;
    const hasUndecided =
      activity.tags?.[Tag.Undecided] && activity.tags[Tag.Undecided].length > 0;

    let newStatus: "accepted" | "declined" | "tentative" | "needsAction";

    // Priority: Attend > Skip > Undecided, using most recent from tagsAdded
    if (hasAttend && (hasSkip || hasUndecided)) {
      // Multiple tags present - use most recent from tagsAdded
      if (Tag.Attend in changes.tagsAdded) {
        newStatus = "accepted";
      } else if (Tag.Skip in changes.tagsAdded) {
        newStatus = "declined";
      } else if (Tag.Undecided in changes.tagsAdded) {
        newStatus = "tentative";
      } else {
        // Multiple were already there, no change needed
        return;
      }
    } else if (hasSkip && hasUndecided) {
      // Skip and Undecided present - use most recent
      if (Tag.Skip in changes.tagsAdded) {
        newStatus = "declined";
      } else if (Tag.Undecided in changes.tagsAdded) {
        newStatus = "tentative";
      } else {
        return;
      }
    } else if (hasAttend) {
      newStatus = "accepted";
    } else if (hasSkip) {
      newStatus = "declined";
    } else if (hasUndecided) {
      newStatus = "tentative";
    } else {
      // No RSVP tags present - reset to needsAction
      newStatus = "needsAction";
    }

    // Extract calendar info from metadata
    if (!activity.meta) {
      console.warn("Missing activity metadata");
      return;
    }

    const baseEventId = activity.meta.id;
    const calendarId = activity.meta.calendarId;

    if (
      !baseEventId ||
      !calendarId ||
      typeof baseEventId !== "string" ||
      typeof calendarId !== "string"
    ) {
      console.warn(
        "Missing or invalid event or calendar ID in activity metadata"
      );
      return;
    }

    // Determine the event ID to update
    // If this is an occurrence-level change, construct the instance ID
    let eventId = baseEventId;
    if (changes.occurrence) {
      // Google Calendar instance IDs are formatted as: {recurringEventId}_{YYYYMMDDTHHMMSSZ}
      const occurrenceDate =
        changes.occurrence.occurrence instanceof Date
          ? changes.occurrence.occurrence
          : new Date(changes.occurrence.occurrence);

      // Format as YYYYMMDDTHHMMSSZ (e.g., 20250115T140000Z)
      const instanceDateStr = occurrenceDate
        .toISOString()
        .replace(/[-:]/g, "") // Remove dashes and colons
        .replace(/\.\d{3}/, ""); // Remove milliseconds

      eventId = `${baseEventId}_${instanceDateStr}`;
    }

    // Get the auth token for this calendar
    const authToken = await this.get<string>(`auth_token_${calendarId}`);

    if (!authToken) {
      console.warn("No auth token found for calendar", calendarId);
      return;
    }

    try {
      await this.updateEventRSVP(authToken, calendarId, eventId, newStatus);
    } catch (error) {
      console.error(`Failed to update RSVP for event ${eventId}:`, error);
    }
  }

  private async updateEventRSVP(
    authToken: string,
    calendarId: string,
    eventId: string,
    status: "accepted" | "declined" | "needsAction" | "tentative"
  ): Promise<void> {
    const api = await this.getApi(authToken);

    // First, fetch the current event to get attendees list
    const event = (await api.call(
      "GET",
      `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events/${eventId}`
    )) as GoogleEvent | null;

    if (!event) {
      throw new Error(`Event ${eventId} not found`);
    }

    // Get user email to find which attendee to update
    const userEmail = await this.get<string>("user_email");

    if (!userEmail) {
      throw new Error("User email not found");
    }

    // Find and update the user's attendee status
    const attendees = event.attendees || [];
    const userAttendeeIndex = attendees.findIndex(
      (att) =>
        att.self === true ||
        att.email?.toLowerCase() === userEmail.toLowerCase()
    );

    if (userAttendeeIndex === -1) {
      console.warn("User is not an attendee of this event");
      return;
    }

    // Check if status already matches to avoid infinite loops
    if (attendees[userAttendeeIndex].responseStatus === status) {
      return;
    }

    // Update the attendee's response status
    attendees[userAttendeeIndex].responseStatus = status;

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
