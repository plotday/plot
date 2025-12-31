import {
  type Activity,
  type ActivityCommon,
  type ActivityLink,
  ActivityLinkType,
  type ActorId,
  ConferencingProvider,
  type NewActivityWithNotes,
  type NewContact,
  type NewNote,
  Tag,
  Tool,
  type ToolBuilder,
} from "@plotday/twister";
import {
  type Calendar,
  type CalendarAuth,
  type CalendarTool,
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
    };
  }

  async requestAuth<
    TCallback extends (auth: CalendarAuth, ...args: any[]) => any
  >(callback: TCallback, ...extraArgs: any[]): Promise<ActivityLink> {
    console.log("Requesting Google Calendar auth");
    const calendarScopes = [
      "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
      "https://www.googleapis.com/auth/calendar.events",
    ];

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
        scopes: calendarScopes,
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

    console.log("Stored user email:", email);
    return email;
  }

  async getCalendars(authToken: string): Promise<Calendar[]> {
    console.log("Fetching Google Calendar list");
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
    console.log("Got Google Calendar list", data.items);

    return data.items.map((item) => ({
      id: item.id,
      name: item.summary,
      description: item.description || null,
      primary: item.primary || false,
    }));
  }

  async startSync<
    TCallback extends (activity: NewActivityWithNotes, ...args: any[]) => any
  >(
    authToken: string,
    calendarId: string,
    callback: TCallback,
    ...extraArgs: any[]
  ): Promise<void> {
    console.log("Saving callback");

    // Create callback token for parent
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );
    await this.set("event_callback_token", callbackToken);

    // Store auth token for calendar for later RSVP updates
    await this.set(`auth_token_${calendarId}`, authToken);

    console.log("Setting up watch");

    // Setup webhook for this calendar
    await this.setupCalendarWatch(authToken, calendarId, authToken);

    // Start initial sync
    const now = new Date();
    const min = new Date(now.getFullYear() - 2, 0, 1);
    const max = new Date(now.getFullYear() + 1, 11, 31);

    const initialState: SyncState = {
      calendarId,
      min,
      max,
      sequence: 1,
    };

    await this.set(`sync_state_${calendarId}`, initialState);

    console.log("Starting sync");
    // Start sync batch using run tool for long-running operation
    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "full",
      authToken,
      calendarId,
      { initialSync: true }
    );
    await this.run(syncCallback);
  }

  async stopSync(_authToken: string, calendarId: string): Promise<void> {
    // Stop webhook
    const watchData = await this.get<any>(`calendar_watch_${calendarId}`);
    if (watchData) {
      // Cancel the watch (would need Google API call)
      await this.clear(`calendar_watch_${calendarId}`);
    }

    // Clear sync state
    await this.clear(`sync_state_${calendarId}`);
  }

  private async setupCalendarWatch(
    authToken: string,
    calendarId: string,
    opaqueAuthToken: string
  ): Promise<void> {
    const webhookUrl = await this.tools.network.createWebhook({
      callback: this.onCalendarWebhook,
      extraArgs: [calendarId, opaqueAuthToken],
    });

    // Check if webhook URL is localhost
    if (URL.parse(webhookUrl)?.hostname === "localhost") {
      console.log("Skipping webhook setup for localhost URL");
      return;
    }

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
    )) as { expiration: string };

    await this.set(`calendar_watch_${calendarId}`, {
      watchId,
      secret,
      calendarId,
      expiry: new Date(parseInt(watchData.expiration)),
    });

    console.log("Calendar watch setup complete", { watchId, calendarId });
  }

  async syncBatch(
    _args: any,
    batchNumber: number,
    mode: "full" | "incremental",
    authToken: string,
    calendarId: string,
    syncMeta: { initialSync: boolean }
  ): Promise<void> {
    console.log(
      `Starting Google Calendar sync batch ${batchNumber} (${mode}) for calendar ${calendarId}`
    );

    try {
      // Ensure we have the user's identity for RSVP tagging
      if (batchNumber === 1) {
        await this.ensureUserIdentity(authToken);
      }

      const state = await this.get<SyncState>(`sync_state_${calendarId}`);
      if (!state) {
        throw new Error("No sync state found");
      }

      // Convert date strings back to Date objects after deserialization
      if (state.min && typeof state.min === "string") {
        state.min = new Date(state.min);
      }
      if (state.max && typeof state.max === "string") {
        state.max = new Date(state.max);
      }

      const api = await this.getApi(authToken);
      const result = await syncGoogleCalendar(api, calendarId, state);

      if (result.events.length > 0) {
        await this.processCalendarEvents(result.events, calendarId, syncMeta);
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
          syncMeta
        );
        await this.run(syncCallback);
      } else {
        console.log(
          `Google Calendar ${mode} sync completed after ${batchNumber} batches for calendar ${calendarId}`
        );
        if (mode === "full") {
          await this.clear(`sync_state_${calendarId}`);
        }
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
    syncMeta: { initialSync: boolean }
  ): Promise<void> {
    // Get user email for RSVP tagging
    const userEmail = await this.get<string>("user_email");

    for (const event of events) {
      try {
        if (event.status === "cancelled") {
          // TODO: Handle event cancellation
          continue;
        }

        // Extract and create contacts from attendees
        let actorIds: ActorId[] = [];
        let validAttendees: typeof event.attendees = [];
        if (event.attendees && event.attendees.length > 0) {
          // Filter to get only valid attendees (with email, not resources)
          validAttendees = event.attendees.filter(
            (att) => att.email && !att.resource
          );

          const contacts: NewContact[] = validAttendees.map((att) => ({
            email: att.email!,
            name: att.displayName,
          }));

          if (contacts.length > 0) {
            const actors = await this.tools.plot.addContacts(contacts);
            actorIds = actors.map((actor) => actor.id);
          }
        }

        // Check if this is a recurring event instance (exception)
        if (event.recurringEventId && event.originalStartTime) {
          await this.processEventException(event, calendarId, syncMeta);
        } else {
          // Regular or master recurring event
          const activityData = transformGoogleEvent(event, calendarId);

          // Determine RSVP status for all attendees and set tags
          let tags: Partial<Record<Tag, ActorId[]>> | null = null;
          if (validAttendees.length > 0) {
            const attendTags: ActorId[] = [];
            const skipTags: ActorId[] = [];
            const undecidedTags: ActorId[] = [];

            // Iterate through valid attendees and group by response status
            validAttendees.forEach((attendee, index) => {
              const actorId = actorIds[index];
              if (actorId) {
                if (attendee.responseStatus === "accepted") {
                  attendTags.push(actorId);
                } else if (attendee.responseStatus === "declined") {
                  skipTags.push(actorId);
                } else if (
                  attendee.responseStatus === "tentative" ||
                  attendee.responseStatus === "needsAction"
                ) {
                  undecidedTags.push(actorId);
                }
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
              if (undecidedTags.length > 0)
                tags[Tag.Undecided] = undecidedTags;
            }
          }

          // Convert to full Activity and call callback
          const callbackToken = await this.get<Callback>(
            "event_callback_token"
          );
          if (callbackToken && activityData.type) {
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

            // Create note with description and/or links
            const notes: NewNote[] = [];
            const description =
              activityData.meta?.description || event.description;
            const hasDescription = description && description.trim().length > 0;
            const hasLinks = links.length > 0;

            if (hasDescription || hasLinks) {
              notes.push({
                activity: { id: "" }, // Will be filled in by the API
                content: hasDescription ? description : null,
                links: hasLinks ? links : null,
                contentType: containsHtml(description) ? "html" : "text",
              });
            }

            const activity: NewActivityWithNotes = {
              type: activityData.type,
              start: activityData.start || null,
              end: activityData.end || null,
              recurrenceUntil: activityData.recurrenceUntil || null,
              recurrenceCount: activityData.recurrenceCount || null,
              doneAt: null,
              title: activityData.title || null,
              recurrenceRule: activityData.recurrenceRule || null,
              recurrenceExdates: activityData.recurrenceExdates || null,
              recurrenceDates: activityData.recurrenceDates || null,
              recurrence: null,
              occurrence: null,
              meta: activityData.meta ?? null,
              tags,
              notes,
            };
            await this.tools.callbacks.run(callbackToken, activity, syncMeta);
          }
        }
      } catch (error) {
        console.error(`Failed to process event ${event.id}:`, error);
        // Continue processing other events
      }
    }
  }

  private async processEventException(
    event: GoogleEvent,
    calendarId: string,
    syncMeta: { initialSync: boolean }
  ): Promise<void> {
    // Similar to processCalendarEvents but for exceptions
    // This would find the master recurring activity and create an exception
    const originalStartTime =
      event.originalStartTime?.dateTime || event.originalStartTime?.date;
    if (!originalStartTime) {
      console.warn(`No original start time for exception: ${event.id}`);
      return;
    }

    const activityData = transformGoogleEvent(event, calendarId);

    const callbackToken = await this.get<Callback>("event_callback_token");
    if (callbackToken && activityData.type) {
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

      // Create note with description and/or links
      const notes: NewNote[] = [];
      const description = activityData.meta?.description || event.description;
      const hasDescription = description && description.trim().length > 0;
      const hasLinks = links.length > 0;

      if (hasDescription || hasLinks) {
        notes.push({
          activity: { id: "" }, // Will be filled in by the API
          content: hasDescription ? description : null,
          links: hasLinks ? links : null,
          contentType: containsHtml(description) ? "html" : "text",
        });
      }

      const activity: NewActivityWithNotes = {
        type: activityData.type,
        start: activityData.start || null,
        end: activityData.end || null,
        recurrenceUntil: activityData.recurrenceUntil || null,
        recurrenceCount: activityData.recurrenceCount || null,
        doneAt: null,
        title: activityData.title || null,
        recurrenceRule: null,
        recurrenceExdates: null,
        recurrenceDates: null,
        recurrence: null, // Would need to find master activity
        occurrence: new Date(originalStartTime),
        meta: activityData.meta ?? null,
        notes,
      };
      await this.tools.callbacks.run(callbackToken, activity, syncMeta);
    }
  }

  async onCalendarWebhook(
    request: WebhookRequest,
    calendarId: string,
    authToken: string
  ): Promise<void> {
    console.log("Received calendar webhook notification", {
      headers: request.headers,
      params: request.params,
      calendarId,
    });

    // Validate webhook authenticity
    const channelId = request.headers["X-Goog-Channel-ID"];
    const channelToken = request.headers["X-Goog-Channel-Token"];

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

    // Trigger incremental sync
    await this.startIncrementalSync(calendarId, authToken);
  }

  private async startIncrementalSync(
    calendarId: string,
    authToken: string
  ): Promise<void> {
    const watchData = await this.get<any>(`calendar_watch_${calendarId}`);
    if (!watchData) {
      console.error("No calendar watch data found");
      return;
    }

    const incrementalState: SyncState = {
      calendarId: watchData.calendarId,
      state:
        (await this.get<string>(`last_sync_token_${calendarId}`)) || undefined,
    };

    await this.set(`sync_state_${calendarId}`, incrementalState);
    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "incremental",
      authToken,
      calendarId,
      { initialSync: false }
    );
    await this.run(syncCallback);
  }

  async onAuthSuccess(
    authResult: Authorization,
    authToken: string,
    callback: Callback
  ): Promise<void> {
    // Store the actual auth token using opaque token as key
    await this.set(`authorization:${authToken}`, authResult);

    const authSuccessResult: CalendarAuth = {
      authToken,
    };

    await this.run(callback, authSuccessResult);

    // Clean up the callback token
    await this.clear(`auth_callback_token:${authToken}`);
  }

  async onActivityUpdated(
    activity: ActivityCommon,
    changes?: {
      previous: ActivityCommon;
      tagsAdded: Record<Tag, ActorId[]>;
      tagsRemoved: Record<Tag, ActorId[]>;
    }
  ): Promise<void> {
    if (!changes) return;
    // Cast to Activity to access Activity-specific fields
    const activityFull = activity as Activity;
    // Only process calendar events
    if (
      !activityFull.meta?.source ||
      !activityFull.meta.source.startsWith("google-calendar:")
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
    const eventId = activityFull.meta.id;
    const calendarId = activityFull.meta.calendarId;

    if (!eventId || !calendarId) {
      console.warn("Missing event or calendar ID in activity metadata");
      return;
    }

    // Get the auth token for this calendar
    const authToken = await this.get<string>(`auth_token_${calendarId}`);

    if (!authToken) {
      console.warn("No auth token found for calendar", calendarId);
      return;
    }

    try {
      await this.updateEventRSVP(authToken, calendarId, eventId, newStatus);
      console.log(`Updated RSVP for event ${eventId} to ${newStatus}`);
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
      console.log(`RSVP status already ${status}, skipping update`);
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
