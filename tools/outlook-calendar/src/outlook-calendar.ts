import {
  type Activity,
  type ActivityLink,
  ActivityLinkType,
  type ActivityOccurrence,
  type NewActivityOccurrence,
  type ActorId,
  ActivityType,
  ConferencingProvider,
  type ContentType,
  type NewActivityWithNotes,
  type NewActor,
  type NewContact,
  type NewNote,
  Serializable,
  Tag,
  Tool,
  type ToolBuilder,
} from "@plotday/twister";
import type {
  Calendar,
  CalendarAuth,
  CalendarTool,
  SyncOptions,
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

type WatchState = {
  subscriptionId: string;
  calendarId: string;
  expiry: Date;
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
 *   private outlookCalendar: OutlookCalendar;
 *
 *   constructor(id: string, tools: Tools) {
 *     super();
 *     this.outlookCalendar = tools.get(OutlookCalendar);
 *   }
 *
 *   async activate() {
 *     const authLink = await this.outlookCalendar.requestAuth("onOutlookAuth", {
 *       provider: "outlook"
 *     });
 *
 *     await this.plot.createActivity({
 *       type: ActivityType.Action,
 *       title: "Connect Outlook Calendar",
 *       links: [authLink]
 *     });
 *   }
 *
 *   async onOutlookAuth(auth: CalendarAuth, context: any) {
 *     const calendars = await this.outlookCalendar.getCalendars(auth.authToken);
 *
 *     // Start syncing primary calendar
 *     const primary = calendars.find(c => c.primary);
 *     if (primary) {
 *       await this.outlookCalendar.startSync(
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
 *   async onCalendarEvent(activity: Activity, context: any) {
 *     // Process Outlook Calendar events
 *     await this.plot.createActivity(activity);
 *   }
 * }
 * ```
 */
export class OutlookCalendar
  extends Tool<OutlookCalendar>
  implements CalendarTool
{
  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: ["https://graph.microsoft.com/*"],
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
    TArgs extends Serializable[],
    TCallback extends (auth: CalendarAuth, ...args: TArgs) => any
  >(callback: TCallback, ...extraArgs: TArgs): Promise<ActivityLink> {
    // Generate opaque token for authorization
    const token = crypto.randomUUID();

    // Create callback token for parent
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );

    // Request Microsoft authentication and return the activity link
    return await this.tools.integrations.request(
      {
        provider: AuthProvider.Microsoft,
        level: AuthLevel.User,
        scopes: ["https://graph.microsoft.com/calendars.readwrite"],
      },
      this.onAuthSuccess,
      token,
      callbackToken
    );
  }

  private async getApi(authToken: string): Promise<GraphApi> {
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

    return new GraphApi(token.token);
  }

  private async getUserEmail(authToken: string): Promise<string> {
    const api = await this.getApi(authToken);
    const data = (await api.call(
      "GET",
      "https://graph.microsoft.com/v1.0/me"
    )) as { mail?: string; userPrincipalName?: string };

    return data.mail || data.userPrincipalName || "";
  }

  private async ensureUserIdentity(authToken: string): Promise<string> {
    // Check if we already have the user email stored
    const stored = await this.get<string>("user_email");
    if (stored) {
      return stored;
    }

    // Fetch user email from Microsoft Graph
    const email = await this.getUserEmail(authToken);

    // Store for future use
    await this.set("user_email", email);

    console.log("Stored user email:", email);
    return email;
  }

  async getCalendars(authToken: string): Promise<Calendar[]> {
    const api = await this.getApi(authToken);
    return await api.getCalendars();
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
    const { authToken, calendarId } = options;
    // Create callback token for parent
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );
    await this.set("event_callback_token", callbackToken);

    // Store auth token for calendar for later RSVP updates
    await this.set(`auth_token_${calendarId}`, authToken);

    // Setup webhook for this calendar
    await this.setupOutlookWatch(authToken, calendarId, authToken);

    // Start sync batch using run tool for long-running operation
    const syncCallback = await this.callback(
      this.syncOutlookBatch,
      calendarId,
      authToken,
      true // initialSync = true for initial sync
    );
    await this.run(syncCallback);
  }

  async stopSync(authToken: string, calendarId: string): Promise<void> {
    // Stop webhook
    const watchData = await this.get<WatchState>(`outlook_watch_${calendarId}`);
    if (watchData?.subscriptionId) {
      try {
        const api = await this.getApi(authToken);
        await api.deleteSubscription(watchData.subscriptionId);
        console.log("Deleted Outlook subscription:", watchData.subscriptionId);
      } catch (error) {
        console.error("Failed to delete Outlook subscription:", error);
        // Continue to clear local state even if API call fails
      }
      await this.clear(`outlook_watch_${calendarId}`);
    }

    // Clear sync state
    await this.clear(`outlook_sync_state_${calendarId}`);
  }

  private async setupOutlookWatch(
    authToken: string,
    calendarId: string,
    opaqueAuthToken: string
  ): Promise<void> {
    const api = await this.getApi(authToken);

    const webhookUrl = await this.tools.network.createWebhook(
      {},
      this.onOutlookWebhook,
      calendarId,
      opaqueAuthToken
    );

    // Skip webhook setup for localhost (development mode)
    if (webhookUrl.includes("localhost") || webhookUrl.includes("127.0.0.1")) {
      console.log("Skipping webhook setup for localhost URL:", webhookUrl);
      return;
    }

    // Microsoft Graph subscriptions expire, so we set expiry for 3 days from now
    const expirationDate = new Date();
    expirationDate.setDate(expirationDate.getDate() + 3);

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

      console.log("Outlook Calendar webhook configured", {
        subscriptionId: subscription.id,
        calendarId,
        expiry: subscription.expirationDateTime,
      });
    } catch (error) {
      console.error("Failed to setup Outlook webhook:", error);
      // Continue without webhook - sync will still work via manual triggers
    }
  }

  async syncOutlookBatch(
    calendarId: string,
    authToken: string,
    initialSync: boolean
  ): Promise<void> {
    let api: GraphApi;

    try {
      api = await this.getApi(authToken);
    } catch (error) {
      console.error(
        "No Microsoft credentials found for the provided authToken:",
        error
      );
      return;
    }

    // Ensure we have the user's identity for RSVP tagging
    await this.ensureUserIdentity(authToken);

    // Load existing sync state
    const savedState = await this.get<SyncState>(
      `outlook_sync_state_${calendarId}`
    );

    const syncState: SyncState = savedState || {
      calendarId,
      sequence: 1,
    };

    let hasMore = true;
    let eventCount = 0;
    const maxEvents = 10000;

    try {
      while (hasMore && eventCount < maxEvents) {
        // Use the syncOutlookCalendar function from graph-api
        const result = await syncOutlookCalendar(api, calendarId, syncState);

        // Process each event
        for (const outlookEvent of result.events) {
          try {
            // Skip deleted events
            if (outlookEvent["@removed"]) {
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
              await this.processEventInstance(
                outlookEvent,
                calendarId,
                initialSync
              );
              continue;
            }

            // Transform the Outlook event to a Plot activity (master or single events)
            const activity = transformOutlookEvent(outlookEvent, calendarId);

            // Skip deleted events (transformOutlookEvent returns null for deleted)
            if (!activity) {
              continue;
            }

            // For recurring events, DON'T add tags at series level
            // Tags (RSVPs) should be per-occurrence via the occurrences array
            // For non-recurring events, add tags normally
            let tags: Partial<Record<Tag, NewActor[]>> | null = null;
            if (validAttendees.length > 0 && !activity.recurrenceRule) {
              const attendTags: NewActor[] = [];
              const skipTags: NewActor[] = [];
              const undecidedTags: NewActor[] = [];

              // Iterate through valid attendees and group by response status
              validAttendees.forEach((attendee) => {
                const newActor: NewActor = {
                  email: attendee.emailAddress!.address!,
                  name: attendee.emailAddress!.name,
                };

                const response = attendee.status?.response;
                if (response === "accepted") {
                  attendTags.push(newActor);
                } else if (response === "declined") {
                  skipTags.push(newActor);
                } else if (
                  response === "tentativelyAccepted" ||
                  response === "none" ||
                  response === "notResponded"
                ) {
                  undecidedTags.push(newActor);
                }
                // organizer has no response status, so they won't get a tag
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

            // Build links array for videoconferencing and calendar links
            const links: ActivityLink[] = [];

            // Add conferencing link if available
            if (outlookEvent.onlineMeeting?.joinUrl) {
              links.push({
                type: ActivityLinkType.conferencing,
                url: outlookEvent.onlineMeeting.joinUrl,
                provider: detectConferencingProvider(
                  outlookEvent.onlineMeeting.joinUrl
                ),
              });
            }

            // Add calendar link
            if (outlookEvent.webLink) {
              links.push({
                type: ActivityLinkType.external,
                title: "View in Calendar",
                url: outlookEvent.webLink,
              });
            }

            // Create note with description and/or links
            const notes: NewNote[] = [];
            const hasDescription =
              outlookEvent.body?.content &&
              outlookEvent.body.content.trim().length > 0;
            const hasLinks = links.length > 0;

            if (hasDescription || hasLinks) {
              notes.push({
                activity: {
                  source:
                    outlookEvent.webLink ||
                    `outlook-calendar:${outlookEvent.id}`,
                },
                key: "description",
                content: hasDescription ? outlookEvent.body!.content! : null,
                links: hasLinks ? links : null,
                contentType: (outlookEvent.body?.contentType === "html"
                  ? "html"
                  : "text") as ContentType,
              });
            }

            // Build NewActivityWithNotes from the transformed activity
            const activityWithNotes: NewActivityWithNotes = {
              ...activity,
              author: authorContact,
              meta: activity.meta,
              tags: tags && Object.keys(tags).length > 0 ? tags : activity.tags,
              notes,
              unread: !initialSync, // false for initial sync, true for incremental updates
            };

            // Call the event callback
            const callbackToken = await this.get<Callback>(
              "event_callback_token"
            );
            if (callbackToken) {
              await this.tools.callbacks.run(callbackToken, activityWithNotes);
            }
          } catch (error) {
            console.error(`Error processing event ${outlookEvent.id}:`, error);
            // Continue processing other events
          }
        }

        // Save sync state
        await this.set(`outlook_sync_state_${calendarId}`, result.state);

        hasMore = result.state.more || false;
        eventCount += result.events.length;

        // Update syncState for next iteration
        Object.assign(syncState, result.state);

        console.log(
          `Synced ${result.events.length} events, total: ${eventCount} for calendar ${calendarId}`
        );
      }

      console.log(
        `Outlook Calendar sync completed: ${eventCount} events for calendar ${calendarId}`
      );
    } catch (error) {
      console.error(`Outlook Calendar sync failed for ${calendarId}:`, error);
      // Re-throw to let the caller handle it
      throw error;
    }
  }

  /**
   * Process a recurring event instance (occurrence or exception) from Outlook Calendar.
   * This updates the master recurring activity with occurrence-specific data.
   */
  private async processEventInstance(
    event: import("./graph-api").OutlookEvent,
    calendarId: string,
    initialSync: boolean
  ): Promise<void> {
    const originalStart = event.originalStart;
    if (!originalStart) {
      console.warn(`No original start time for instance: ${event.id}`);
      return;
    }

    // The seriesMasterId points to the master activity
    if (!event.seriesMasterId) {
      console.warn(`No series master ID for instance: ${event.id}`);
      return;
    }

    // Canonical URL for the master recurring event
    const masterCanonicalUrl = `outlook-calendar:${calendarId}:${event.seriesMasterId}`;

    // Transform the instance data
    const instanceData = transformOutlookEvent(event, calendarId);

    if (!instanceData) {
      return; // Skip deleted events
    }

    // Determine RSVP status for attendees
    const validAttendees =
      event.attendees?.filter(
        (att) => att.emailAddress?.address && att.type !== "resource"
      ) || [];

    let tags: Partial<Record<Tag, import("@plotday/twister").NewActor[]>> = {};
    if (validAttendees.length > 0) {
      const attendTags: import("@plotday/twister").NewActor[] = [];
      const skipTags: import("@plotday/twister").NewActor[] = [];
      const undecidedTags: import("@plotday/twister").NewActor[] = [];

      validAttendees.forEach((attendee) => {
        const newActor: import("@plotday/twister").NewActor = {
          email: attendee.emailAddress!.address!,
          name: attendee.emailAddress!.name,
        };

        const response = attendee.status?.response;
        if (response === "accepted") {
          attendTags.push(newActor);
        } else if (response === "declined") {
          skipTags.push(newActor);
        } else if (
          response === "tentativelyAccepted" ||
          response === "none" ||
          response === "notResponded"
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
    // rescheduled instances), otherwise fall back to originalStart.
    const occurrenceStart = instanceData.start ?? new Date(originalStart);

    const occurrence: Omit<NewActivityOccurrence, "activity"> = {
      occurrence: new Date(originalStart),
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
    const callbackToken = await this.get<Callback>("event_callback_token");
    if (!callbackToken) {
      console.warn("No callback token found for occurrence update");
      return;
    }

    // Build a minimal NewActivity with source and occurrences
    // The twist's createActivity will upsert the master activity
    const occurrenceUpdate = {
      type: ActivityType.Event,
      source: masterCanonicalUrl,
      occurrences: [occurrence],
    };

    await this.tools.callbacks.run(callbackToken, occurrenceUpdate);
  }

  async onOutlookWebhook(
    request: WebhookRequest,
    calendarId: string,
    authToken: string
  ): Promise<void> {
    console.log("Received Outlook calendar webhook notification", {
      calendarId,
    });

    if (request.params?.validationToken) {
      // Return validation token for webhook verification
      return;
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

    for (const notification of notifications) {
      if (notification.changeType) {
        console.log(
          `Calendar ${notification.changeType} notification for ${calendarId}`
        );

        // Trigger incremental sync
        await this.startIncrementalSync(calendarId, authToken);
      }
    }
  }

  private async startIncrementalSync(
    calendarId: string,
    authToken: string
  ): Promise<void> {
    console.log("Starting incremental Outlook Calendar sync for", calendarId);

    try {
      await this.getApi(authToken);
    } catch (error) {
      console.error(
        "No Microsoft credentials found for the provided authToken:",
        error
      );
      return;
    }

    const callback = await this.callback(
      this.syncOutlookBatch,
      calendarId,
      authToken,
      false // initialSync = false for incremental updates
    );
    await this.run(callback);
  }

  async onAuthSuccess(
    authResult: Authorization,
    token: string,
    callbackToken: Callback
  ): Promise<void> {
    // Store the actual auth token using opaque token as key
    await this.set(`authorization:${token}`, authResult);

    const authSuccessResult: CalendarAuth = {
      authToken: token,
    };

    await this.run(callbackToken, authSuccessResult);
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
      !source.startsWith("outlook-calendar:")
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

    let newStatus: "accepted" | "declined" | "tentativelyAccepted";

    // Priority: Attend > Skip > Undecided, using most recent from tagsAdded
    if (hasAttend && (hasSkip || hasUndecided)) {
      // Multiple tags present - use most recent from tagsAdded
      if (Tag.Attend in changes.tagsAdded) {
        newStatus = "accepted";
      } else if (Tag.Skip in changes.tagsAdded) {
        newStatus = "declined";
      } else if (Tag.Undecided in changes.tagsAdded) {
        newStatus = "tentativelyAccepted";
      } else {
        // Multiple were already there, no change needed
        return;
      }
    } else if (hasSkip && hasUndecided) {
      // Skip and Undecided present - use most recent
      if (Tag.Skip in changes.tagsAdded) {
        newStatus = "declined";
      } else if (Tag.Undecided in changes.tagsAdded) {
        newStatus = "tentativelyAccepted";
      } else {
        return;
      }
    } else if (hasAttend) {
      newStatus = "accepted";
    } else if (hasSkip) {
      newStatus = "declined";
    } else if (hasUndecided) {
      newStatus = "tentativelyAccepted";
    } else {
      // No RSVP tags present - reset to tentativelyAccepted (acts as "needsAction")
      newStatus = "tentativelyAccepted";
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
    // If this is an occurrence-level change, look up the instance ID
    let eventId = baseEventId;
    if (changes.occurrence) {
      const occurrenceDate =
        changes.occurrence.occurrence instanceof Date
          ? changes.occurrence.occurrence
          : new Date(changes.occurrence.occurrence);

      console.log(`Looking up instance for occurrence: ${occurrenceDate.toISOString()}`);

      // Get the auth token for this calendar
      const authToken = await this.get<string>(`auth_token_${calendarId}`);

      if (!authToken) {
        console.warn("No auth token found for calendar", calendarId);
        return;
      }

      try {
        // Look up the instance ID for this occurrence
        const instanceId = await this.getEventInstanceId(
          authToken,
          calendarId,
          baseEventId,
          occurrenceDate
        );

        if (instanceId) {
          eventId = instanceId;
          console.log(`Updating occurrence instance: ${eventId}`);
        } else {
          console.warn(`Could not find instance ID for occurrence ${occurrenceDate.toISOString()}`);
          return;
        }
      } catch (error) {
        console.error(`Failed to look up instance ID:`, error);
        return;
      }
    }

    // Get the auth token for this calendar (if not already retrieved above)
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

  /**
   * Look up the instance ID for a specific occurrence of a recurring event.
   * Uses the Microsoft Graph instances endpoint to find the matching occurrence.
   */
  private async getEventInstanceId(
    authToken: string,
    calendarId: string,
    seriesMasterId: string,
    occurrenceDate: Date
  ): Promise<string | null> {
    const api = await this.getApi(authToken);

    // Query instances for the series master
    const resource =
      calendarId === "primary"
        ? `/me/events/${seriesMasterId}/instances`
        : `/me/calendars/${calendarId}/events/${seriesMasterId}/instances`;

    // Format occurrence date as ISO string for comparison
    const occurrenceDateStr = occurrenceDate.toISOString();

    try {
      // Query instances from the API
      const response = await api.call("GET", `https://graph.microsoft.com/v1.0${resource}`);

      if (!response || !Array.isArray(response.value)) {
        console.warn("Invalid response from instances endpoint");
        return null;
      }

      const instances = response.value as import("./graph-api").OutlookEvent[];

      // Find the instance that matches this occurrence
      // Match by originalStart (for exceptions) or start (for regular occurrences)
      for (const instance of instances) {
        const instanceStart = instance.originalStart || instance.start?.dateTime;
        if (instanceStart) {
          const instanceDate = new Date(instanceStart);
          // Compare with a tolerance of 1 second to account for rounding
          const diff = Math.abs(instanceDate.getTime() - occurrenceDate.getTime());
          if (diff < 1000) {
            return instance.id;
          }
        }
      }

      // If no exact match, log for debugging
      console.warn(
        `No instance found matching occurrence ${occurrenceDateStr}. Found ${instances.length} instances.`
      );
      return null;
    } catch (error) {
      console.error(`Failed to query instances for ${seriesMasterId}:`, error);
      return null;
    }
  }

  private async updateEventRSVP(
    authToken: string,
    calendarId: string,
    eventId: string,
    status: "accepted" | "declined" | "tentativelyAccepted"
  ): Promise<void> {
    const api = await this.getApi(authToken);

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

    // Get user email to find which attendee to check
    const userEmail = await this.get<string>("user_email");

    if (!userEmail) {
      throw new Error("User email not found");
    }

    // Check current user's response status to avoid infinite loops
    const attendees = event.attendees || [];
    const userAttendee = attendees.find(
      (att: any) =>
        att.emailAddress?.address?.toLowerCase() === userEmail.toLowerCase()
    );

    if (userAttendee && userAttendee.status?.response === status) {
      console.log(`RSVP status already ${status}, skipping update`);
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
