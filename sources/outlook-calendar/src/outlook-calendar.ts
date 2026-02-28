import {
  type Action,
  ActionType,
  type ActorId,
  ConferencingProvider,
  type ContentType,
  type NewLinkWithNotes,
  type NewContact,
  Source,
  type ToolBuilder,
} from "@plotday/twister";
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
export class OutlookCalendar extends Source<OutlookCalendar> {
  static readonly PROVIDER = AuthProvider.Microsoft;
  static readonly SCOPES = ["https://graph.microsoft.com/calendars.readwrite"];

  readonly provider = AuthProvider.Microsoft;
  readonly scopes = OutlookCalendar.SCOPES;
  readonly linkTypes = [{ type: "event", label: "Event", logo: "https://api.iconify.design/simple-icons/microsoftoutlook.svg" }];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://graph.microsoft.com/*"] }),
    };
  }

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
   */
  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // Auto-start sync: setup watch and queue first batch
    await this.setupOutlookWatch(channel.id);

    // Determine default sync range (2 years into the past)
    const now = new Date();
    const min = new Date(now.getFullYear() - 2, 0, 1);

    await this.set(`outlook_sync_state_${channel.id}`, {
      calendarId: channel.id,
      min,
      sequence: 1,
    } as SyncState);

    const syncCallback = await this.callback(
      this.syncOutlookBatch,
      channel.id,
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

  private async getApi(calendarId: string): Promise<GraphApi> {
    const token = await this.tools.integrations.get(calendarId);
    if (!token) {
      throw new Error("No Microsoft authentication token available");
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
    // Stop webhook
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

    // Clear sync state
    await this.clear(`outlook_sync_state_${calendarId}`);
  }

  private async setupOutlookWatch(calendarId: string): Promise<void> {
    const api = await this.getApi(calendarId);

    const webhookUrl = await this.tools.network.createWebhook(
      {},
      this.onOutlookWebhook,
      calendarId
    );

    // Skip webhook setup for localhost (development mode)
    if (webhookUrl.includes("localhost") || webhookUrl.includes("127.0.0.1")) {
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
    let api: GraphApi;

    try {
      api = await this.getApi(calendarId);
    } catch (error) {
      console.error("No Microsoft credentials found for calendar:", error);
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

    try {
      // Process ONE batch (single API page) instead of while loop
      const result = await syncOutlookCalendar(api, calendarId, syncState);

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
        console.log(
          `Outlook Calendar sync completed after ${batchNumber} batches for calendar ${calendarId}`
        );
      }
    } catch (error) {
      console.error(
        `Outlook Calendar sync failed for ${calendarId} in batch ${batchNumber}:`,
        error
      );
      // Re-throw to let the caller handle it
      throw error;
    }
  }

  /**
   * Process Outlook events from a sync batch.
   */
  private async processOutlookEvents(
    events: import("./graph-api").OutlookEvent[],
    calendarId: string,
    initialSync: boolean
  ): Promise<void> {
    for (const outlookEvent of events) {
      try {
        // Handle deleted events
        if (outlookEvent["@removed"]) {
          // On initial sync, skip creating threads for already-deleted events
          if (initialSync) {
            continue;
          }
          // Build source URL using event ID
          const source = `outlook-calendar:${outlookEvent.id}`;

          // Create cancellation note
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
            channelId: calendarId,
            meta: { syncProvider: "microsoft", syncableId: calendarId },
            notes: [cancelNote],
            ...(initialSync ? { unread: false } : {}), // false for initial sync, omit for incremental updates
            ...(initialSync ? { archived: false } : {}), // unarchive on initial sync only
          };

          // Send link update
          await this.tools.integrations.saveLink(link);
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

        // For recurring events, DON'T add contacts at series level
        // Contacts (RSVPs) should be per-occurrence via the scheduleOccurrences array
        // For non-recurring events, add contacts to the schedule
        const hasRecurrence = !!threadData.schedules?.[0]?.recurrenceRule;
        if (validAttendees.length > 0 && !hasRecurrence && threadData.schedules?.[0]) {
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

        // Build description note if available
        const hasDescription =
          outlookEvent.body?.content &&
          outlookEvent.body.content.trim().length > 0;
        const hasActions = actions.length > 0;

        const descriptionNote = hasDescription ? {
          key: "description",
          content: outlookEvent.body!.content!,
          contentType: (outlookEvent.body?.contentType === "html"
            ? "html"
            : "text") as ContentType,
        } : null;

        // Build NewLinkWithNotes from the transformed thread data
        const linkWithNotes: NewLinkWithNotes = {
          source: `outlook-calendar:${outlookEvent.id}`,
          type: "event",
          title: threadData.title || "",
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
          notes: descriptionNote ? [descriptionNote] : [],
          preview: hasDescription ? outlookEvent.body!.content! : null,
          schedules: threadData.schedules,
          scheduleOccurrences: threadData.scheduleOccurrences,
          ...(initialSync ? { unread: false } : {}), // false for initial sync, omit for incremental updates
          ...(initialSync ? { archived: false } : {}), // unarchive on initial sync only
        };

        // Save link - database handles upsert automatically
        await this.tools.integrations.saveLink(linkWithNotes);
      } catch (error) {
        console.error(`Error processing event ${outlookEvent.id}:`, error);
        // Continue processing other events
      }
    }
  }

  /**
   * Process a recurring event instance (occurrence or exception) from Outlook Calendar.
   * This updates the master recurring thread with occurrence-specific data.
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

    // The seriesMasterId points to the master thread
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

    // Handle cancelled recurring instances by archiving the occurrence
    if (event.isCancelled) {
      const cancelledOccurrence: NewScheduleOccurrence = {
        occurrence: new Date(originalStart),
        start: new Date(originalStart),
        archived: true,
      };

      const occurrenceUpdate: NewLinkWithNotes = {
        type: "event",
        title: "",
        source: masterCanonicalUrl,
        channelId: calendarId,
        meta: { syncProvider: "microsoft", syncableId: calendarId },
        scheduleOccurrences: [cancelledOccurrence],
        notes: [],
      };

      await this.tools.integrations.saveLink(occurrenceUpdate);
      return;
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

    // Send occurrence data via saveLink
    // Build a minimal link with source and scheduleOccurrences
    const occurrenceUpdate: NewLinkWithNotes = {
      type: "event",
      title: "",
      source: masterCanonicalUrl,
      channelId: calendarId,
      meta: { syncProvider: "microsoft", syncableId: calendarId },
      scheduleOccurrences: [occurrence],
      notes: [],
    };

    await this.tools.integrations.saveLink(occurrenceUpdate);
  }

  async onOutlookWebhook(
    request: WebhookRequest,
    calendarId: string
  ): Promise<void> {
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
        // Trigger incremental sync
        await this.startIncrementalSync(calendarId);
      }
    }
  }

  private async startIncrementalSync(calendarId: string): Promise<void> {
    try {
      await this.getApi(calendarId);
    } catch (error) {
      console.error("No Microsoft credentials found for calendar:", error);
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
   * Sync a schedule contact RSVP change back to Outlook Calendar.
   * Called via actAs() which provides the actor's auth token.
   */
  async syncActorRSVP(
    token: AuthToken,
    calendarId: string,
    eventId: string,
    status: "accepted" | "declined" | "tentativelyAccepted",
    actorId: string
  ): Promise<void> {
    try {
      const api = new GraphApi(token.token);
      await this.updateEventRSVPWithApi(
        api,
        calendarId,
        eventId,
        status,
        actorId as ActorId
      );
    } catch (error) {
      console.error("[RSVP Sync] Failed to sync RSVP", {
        event_id: eventId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  /**
   * Look up the instance ID for a specific occurrence using a pre-authenticated GraphApi.
   */
  private async getEventInstanceIdWithApi(
    api: GraphApi,
    calendarId: string,
    seriesMasterId: string,
    occurrenceDate: Date
  ): Promise<string | null> {
    // Query instances for the series master
    const resource =
      calendarId === "primary"
        ? `/me/events/${seriesMasterId}/instances`
        : `/me/calendars/${calendarId}/events/${seriesMasterId}/instances`;

    // Format occurrence date as ISO string for comparison
    const occurrenceDateStr = occurrenceDate.toISOString();

    try {
      // Query instances from the API
      const response = await api.call(
        "GET",
        `https://graph.microsoft.com/v1.0${resource}`
      );

      if (!response || !Array.isArray(response.value)) {
        console.warn("Invalid response from instances endpoint");
        return null;
      }

      const instances = response.value as import("./graph-api").OutlookEvent[];

      // Find the instance that matches this occurrence
      // Match by originalStart (for exceptions) or start (for regular occurrences)
      for (const instance of instances) {
        const instanceStart =
          instance.originalStart || instance.start?.dateTime;
        if (instanceStart) {
          const instanceDate = new Date(instanceStart);
          // Compare with a tolerance of 1 second to account for rounding
          const diff = Math.abs(
            instanceDate.getTime() - occurrenceDate.getTime()
          );
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
