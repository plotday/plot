import {
  type Activity,
  type ActivityLink,
  ActivityLinkType,
  type ActivityOccurrence,
  ActivityType,
  type ActorId,
  ConferencingProvider,
  type ContentType,
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
import type {
  Calendar,
  CalendarTool,
  SyncOptions,
} from "@plotday/twister/common/calendar";
import { type Callback } from "@plotday/twister/tools/callbacks";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Syncable,
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
 *   build(build: ToolBuilder) {
 *     return {
 *       outlookCalendar: build(OutlookCalendar),
 *       plot: build(Plot, { activity: { access: ActivityAccess.Create } }),
 *     };
 *   }
 *
 *   // Auth and calendar selection handled in the twist edit modal.
 *   // Events are delivered via the startSync callback.
 * }
 * ```
 */
export class OutlookCalendar
  extends Tool<OutlookCalendar>
  implements CalendarTool
{
  static readonly PROVIDER = AuthProvider.Microsoft;
  static readonly SCOPES = ["https://graph.microsoft.com/calendars.readwrite"];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations, {
        providers: [{
          provider: OutlookCalendar.PROVIDER,
          scopes: OutlookCalendar.SCOPES,
          getSyncables: this.getSyncables,
          onSyncEnabled: this.onSyncEnabled,
          onSyncDisabled: this.onSyncDisabled,
        }],
      }),
      network: build(Network, { urls: ["https://graph.microsoft.com/*"] }),
      plot: build(Plot, {
        contact: { access: ContactAccess.Write },
        activity: { access: ActivityAccess.Create, updated: this.onActivityUpdated },
      }),
    };
  }

  /**
   * Returns available Outlook calendars as syncable resources.
   */
  async getSyncables(_auth: Authorization, token: AuthToken): Promise<Syncable[]> {
    const api = new GraphApi(token.token);
    const calendars = await api.getCalendars();
    return calendars.map((c) => ({ id: c.id, title: c.name }));
  }

  /**
   * Called when a syncable calendar is enabled for syncing.
   */
  async onSyncEnabled(syncable: Syncable): Promise<void> {
    await this.set(`sync_enabled_${syncable.id}`, true);
  }

  /**
   * Called when a syncable calendar is disabled.
   */
  async onSyncDisabled(syncable: Syncable): Promise<void> {
    await this.stopSync(syncable.id);
    await this.clear(`sync_enabled_${syncable.id}`);
  }

  private async getApi(calendarId: string): Promise<GraphApi> {
    const token = await this.tools.integrations.get(OutlookCalendar.PROVIDER, calendarId);
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

  async startSync<
    TArgs extends Serializable[],
    TCallback extends (activity: NewActivityWithNotes, ...args: TArgs) => any
  >(
    options: {
      calendarId: string;
    } & SyncOptions,
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<void> {
    const { calendarId, timeMin, timeMax } = options;
    // Create callback token for parent
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );
    await this.set("event_callback_token", callbackToken);

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

  private async setupOutlookWatch(
    calendarId: string
  ): Promise<void> {
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
      console.error(
        "No Microsoft credentials found for calendar:",
        error
      );
      return;
    }

    // Ensure we have the user's identity for RSVP tagging (only on first batch)
    if (batchNumber === 1) {
      await this.ensureUserIdentity(calendarId);
    }

    // Hoist callback token retrieval outside event loop - saves N-1 subrequests
    const callbackToken = await this.get<Callback>("event_callback_token");
    if (!callbackToken) {
      console.warn("No callback token found, skipping event processing");
      return;
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

      // Process events with hoisted callback token
      await this.processOutlookEvents(
        result.events,
        calendarId,
        initialSync,
        callbackToken
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
   * Extracted to receive hoisted callback token and reduce subrequests.
   */
  private async processOutlookEvents(
    events: import("./graph-api").OutlookEvent[],
    calendarId: string,
    initialSync: boolean,
    callbackToken: Callback
  ): Promise<void> {
    for (const outlookEvent of events) {
      try {
        // Handle deleted events
        if (outlookEvent["@removed"]) {
          // On initial sync, skip creating activities for already-deleted events
          if (initialSync) {
            continue;
          }
          // Build source URL using event ID
          const source = `outlook-calendar:${outlookEvent.id}`;

          // Create cancellation note
          const cancelNote: NewNote = {
            activity: { source },
            key: "cancellation",
            content: "This event was cancelled.",
            contentType: "text",
            created: outlookEvent.lastModifiedDateTime
              ? new Date(outlookEvent.lastModifiedDateTime)
              : new Date(),
          };

          // Convert to Note type with blocked tag and cancellation note
          const activity: NewActivityWithNotes = {
            type: ActivityType.Note,
            created: outlookEvent.createdDateTime
              ? new Date(outlookEvent.createdDateTime)
              : new Date(),
            preview: "Cancelled",
            source,
            notes: [cancelNote],
            ...(initialSync ? { unread: false } : {}), // false for initial sync, omit for incremental updates
            ...(initialSync ? { archived: false } : {}), // unarchive on initial sync only
          };

          // Send activity update
          await this.tools.callbacks.run(callbackToken, activity);
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
            initialSync,
            callbackToken
          );
          continue;
        }

        // Transform the Outlook event to a Plot activity (master or single events)
        const activity = transformOutlookEvent(outlookEvent, calendarId);

        // Skip deleted events (transformOutlookEvent returns null for deleted)
        if (!activity) {
          continue;
        }

        // On initial sync, skip cancelled standalone events
        if (initialSync && outlookEvent.isCancelled) {
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
            if (undecidedTags.length > 0) tags[Tag.Undecided] = undecidedTags;
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
              source: `outlook-calendar:${outlookEvent.id}`,
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
          preview: hasDescription ? outlookEvent.body!.content! : null,
          ...(initialSync ? { unread: false } : {}), // false for initial sync, omit for incremental updates
          ...(initialSync ? { archived: false } : {}), // unarchive on initial sync only
        };

        // Call the event callback using hoisted token
        await this.tools.callbacks.run(callbackToken, activityWithNotes);
      } catch (error) {
        console.error(`Error processing event ${outlookEvent.id}:`, error);
        // Continue processing other events
      }
    }
  }

  /**
   * Process a recurring event instance (occurrence or exception) from Outlook Calendar.
   * This updates the master recurring activity with occurrence-specific data.
   */
  private async processEventInstance(
    event: import("./graph-api").OutlookEvent,
    calendarId: string,
    initialSync: boolean,
    callbackToken: Callback
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

    // Handle cancelled recurring instances by adding to recurrence exdates
    if (event.isCancelled) {
      const start = instanceData?.start ?? new Date(originalStart);
      const end = instanceData?.end ?? null;

      const occurrenceUpdate = {
        type: ActivityType.Event,
        source: masterCanonicalUrl,
        start: start,
        end: end,
        addRecurrenceExdates: [new Date(originalStart)],
      };

      await this.tools.callbacks.run(callbackToken, occurrenceUpdate);
      return;
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
      ...(initialSync ? { unread: false } : {}),
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

  private async startIncrementalSync(
    calendarId: string
  ): Promise<void> {
    try {
      await this.getApi(calendarId);
    } catch (error) {
      console.error(
        "No Microsoft credentials found for calendar:",
        error
      );
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

  async onActivityUpdated(
    activity: Activity,
    changes: {
      tagsAdded: Record<Tag, ActorId[]>;
      tagsRemoved: Record<Tag, ActorId[]>;
      occurrence?: ActivityOccurrence;
    }
  ): Promise<void> {
    try {
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

      // Collect unique actor IDs from RSVP tag changes
      const actorIds = new Set<ActorId>();
      for (const tag of [Tag.Attend, Tag.Skip, Tag.Undecided]) {
        if (tag in changes.tagsAdded) {
          for (const id of changes.tagsAdded[tag]) actorIds.add(id);
        }
        if (tag in changes.tagsRemoved) {
          for (const id of changes.tagsRemoved[tag]) actorIds.add(id);
        }
      }

      // Determine new RSVP status based on most recent tag change
      const hasAttend =
        activity.tags?.[Tag.Attend] && activity.tags[Tag.Attend].length > 0;
      const hasSkip =
        activity.tags?.[Tag.Skip] && activity.tags[Tag.Skip].length > 0;
      const hasUndecided =
        activity.tags?.[Tag.Undecided] &&
        activity.tags[Tag.Undecided].length > 0;

      let newStatus: "accepted" | "declined" | "tentativelyAccepted";

      // Priority: Attend > Skip > Undecided, using most recent from tagsAdded
      if (hasAttend && (hasSkip || hasUndecided)) {
        if (Tag.Attend in changes.tagsAdded) {
          newStatus = "accepted";
        } else if (Tag.Skip in changes.tagsAdded) {
          newStatus = "declined";
        } else if (Tag.Undecided in changes.tagsAdded) {
          newStatus = "tentativelyAccepted";
        } else {
          return;
        }
      } else if (hasSkip && hasUndecided) {
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
        console.error("[RSVP Sync] Missing activity metadata", {
          activity_id: activity.id,
        });
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
        console.error("[RSVP Sync] Missing or invalid event/calendar ID", {
          has_event_id: !!baseEventId,
          has_calendar_id: !!calendarId,
          event_id_type: typeof baseEventId,
          calendar_id_type: typeof calendarId,
        });
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

        try {
          const api = await this.getApi(calendarId as string);
          const instanceId = await this.getEventInstanceIdWithApi(
            api,
            calendarId as string,
            baseEventId,
            occurrenceDate
          );
          if (instanceId) {
            eventId = instanceId;
          } else {
            console.warn(
              `Could not find instance ID for occurrence ${occurrenceDate.toISOString()}`
            );
            return;
          }
        } catch (error) {
          console.error(`Failed to look up instance ID:`, error);
          return;
        }
      }

      // For each actor who changed RSVP, use actAs() to sync with their credentials.
      // If the actor has auth, the callback fires immediately.
      // If not, actAs() creates a private auth note automatically.
      for (const actorId of actorIds) {
        await this.tools.integrations.actAs(
          OutlookCalendar.PROVIDER,
          actorId,
          activity.id,
          this.syncActorRSVP,
          calendarId as string,
          eventId,
          newStatus,
          actorId as string
        );
      }
    } catch (error) {
      console.error("[RSVP Sync] Error in callback", {
        error: error instanceof Error ? error.message : String(error),
        stack: error instanceof Error ? error.stack : undefined,
        activity_id: activity.id,
      });
    }
  }

  /**
   * Sync RSVP for an actor. If the actor has auth, this is called immediately.
   * If not, actAs() creates a private auth note and calls this when they authorize.
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
        actor_id: actorId,
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
   * Update RSVP status for a specific actor using a pre-authenticated GraphApi instance.
   * Looks up the actor's email from the Graph API to find the correct attendee.
   */
  private async updateEventRSVPWithApi(
    api: GraphApi,
    calendarId: string,
    eventId: string,
    status: "accepted" | "declined" | "tentativelyAccepted",
    actorId: ActorId
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
      console.warn("[RSVP Sync] Could not determine actor email", {
        actor_id: actorId,
      });
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
        actor_id: actorId,
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
