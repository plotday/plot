import {
  type Activity,
  type ActivityLink,
  ActivityLinkType,
  type ActivityUpdate,
  type ActorId,
  ConferencingProvider,
  type NewActivityWithNotes,
  type NewContact,
  type NewNote,
  Tag,
  Tool,
  type ToolBuilder,
} from "@plotday/twister";
import type {
  Calendar,
  CalendarAuth,
  CalendarTool,
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
    TCallback extends (auth: CalendarAuth, ...args: any[]) => any
  >(callback: TCallback, ...extraArgs: any[]): Promise<ActivityLink> {
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
    TCallback extends (activity: NewActivityWithNotes, ...args: any[]) => any
  >(
    authToken: string,
    calendarId: string,
    callback: TCallback,
    ...extraArgs: any[]
  ): Promise<void> {
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

    const webhookUrl = await this.tools.network.createWebhook({
      callback: this.onOutlookWebhook,
      extraArgs: [calendarId, opaqueAuthToken],
    });

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

    // Get user email for RSVP tagging
    const userEmail = await this.get<string>("user_email");

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

            // Extract and create contacts from attendees
            let actorIds: ActorId[] = [];
            let validAttendees: typeof outlookEvent.attendees = [];
            if (outlookEvent.attendees && outlookEvent.attendees.length > 0) {
              // Filter to get only valid attendees (with email, not resources)
              validAttendees = outlookEvent.attendees.filter(
                (att) => att.emailAddress?.address && att.type !== "resource"
              );

              const contacts: NewContact[] = validAttendees.map((att) => ({
                email: att.emailAddress!.address!,
                name: att.emailAddress!.name,
              }));

              if (contacts.length > 0) {
                const actors = await this.tools.plot.addContacts(contacts);
                actorIds = actors.map((actor) => actor.id);
              }
            }

            // Transform the Outlook event to a Plot activity
            const activity = transformOutlookEvent(outlookEvent, calendarId);

            // Skip deleted events (transformOutlookEvent returns null for deleted)
            if (!activity) {
              continue;
            }

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
                  const response = attendee.status?.response;
                  if (response === "accepted") {
                    attendTags.push(actorId);
                  } else if (response === "declined") {
                    skipTags.push(actorId);
                  } else if (
                    response === "tentativelyAccepted" ||
                    response === "none" ||
                    response === "notResponded"
                  ) {
                    undecidedTags.push(actorId);
                  }
                  // organizer has no response status, so they won't get a tag
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
                activity: { id: "" }, // Will be filled in by the API
                content: hasDescription ? outlookEvent.body!.content! : null,
                links: hasLinks ? links : null,
                contentType:
                  outlookEvent.body?.contentType === "html" ? "html" : "text",
              });
            }

            // Build NewActivityWithNotes from the transformed activity
            const activityWithNotes: NewActivityWithNotes = {
              ...activity,
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
              await this.tools.callbacks.run(
                callbackToken,
                activityWithNotes
              );
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

    const notifications = request.body?.value;
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
      update: ActivityUpdate;
      previous: Activity;
      tagsAdded: Record<Tag, ActorId[]>;
      tagsRemoved: Record<Tag, ActorId[]>;
    }
  ): Promise<void> {
    // Only process calendar events
    if (
      !activity.meta?.source ||
      !activity.meta.source.startsWith("outlook-calendar:")
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
    const eventId = activity.meta.id;
    const calendarId = activity.meta.calendarId;

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
