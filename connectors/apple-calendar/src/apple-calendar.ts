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
import { Options } from "@plotday/twister/options";
import type {
  NewSchedule,
  NewScheduleContact,
  NewScheduleOccurrence,
  ScheduleContactStatus,
} from "@plotday/twister/schedule";
import {
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";

import { CalDAVClient, type CalDAVEvent, toCalDAVTimeString } from "./caldav";
import {
  type ICSEvent,
  parseICSDateTime,
  parseICSEvents,
  parseRRuleCount,
  parseRRuleEnd,
  updateAttendeePartstat,
} from "./ics-parser";

type SyncState = {
  calendarHref: string;
  initialSync: boolean;
  batchNumber: number;
  /** Event hrefs remaining to process (for batched multiget) */
  pendingHrefs?: string[];
};

type PendingOccurrence = {
  occurrence: NewScheduleOccurrence;
  cancelled: boolean;
};

/**
 * Apple Calendar connector — syncs events from iCloud via CalDAV.
 *
 * Uses app-specific password authentication (no OAuth).
 * Polls for changes using ctag/etag change detection since CalDAV
 * does not support push notifications.
 */
export class AppleCalendar extends Connector<AppleCalendar> {
  readonly linkTypes = [
    {
      type: "event",
      label: "Event",
      logo: "https://plot.day/assets/logo-apple-calendar.svg",
      logoMono: "https://api.iconify.design/simple-icons/apple.svg",
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      options: build(Options, {
        appleId: {
          type: "text" as const,
          label: "Apple ID",
          default: "",
          placeholder: "you@icloud.com",
        },
        appPassword: {
          type: "text" as const,
          secure: true,
          label: "App-Specific Password",
          default: "",
          placeholder: "xxxx-xxxx-xxxx-xxxx",
          description:
            "Generate at appleid.apple.com > Sign-In and Security > App-Specific Passwords",
        },
      }),
      network: build(Network, {
        urls: ["https://caldav.icloud.com/*", "https://*.icloud.com/*"],
      }),
      tasks: build(Tasks),
    };
  }

  // ---- Helpers ----

  private getCalDAV(): CalDAVClient {
    const appleId = this.tools.options.appleId as string;
    const appPassword = this.tools.options.appPassword as string;
    if (!appleId || !appPassword) {
      throw new Error(
        "Apple ID and app-specific password are required. Configure them in the connector options."
      );
    }
    return new CalDAVClient({ appleId, appPassword });
  }

  /**
   * Discover principal and calendar home, caching the results.
   */
  private async discoverCalendarHome(): Promise<string> {
    const cached = await this.get<string>("calendar_home");
    if (cached) return cached;

    const client = this.getCalDAV();
    const principal = await client.discoverPrincipal();
    await this.set("principal_url", principal);

    const calendarHome = await client.discoverCalendarHome(principal);
    await this.set("calendar_home", calendarHome);

    return calendarHome;
  }

  // ---- Channel Lifecycle ----

  /**
   * Returns available iCloud calendars as channels.
   * Auth params are null since we use Options for credentials.
   */
  async getChannels(
    _auth: Authorization | null,
    _token: AuthToken | null
  ): Promise<Channel[]> {
    const calendarHome = await this.discoverCalendarHome();
    const client = this.getCalDAV();
    const calendars = await client.listCalendars(calendarHome);
    return calendars.map((c) => ({ id: c.href, title: c.displayName }));
  }

  /**
   * Called when a calendar channel is enabled for syncing.
   */
  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // Store initial ctag for incremental sync
    const client = this.getCalDAV();
    const ctag = await client.getCalendarCtag(channel.id);
    if (ctag) await this.set(`ctag_${channel.id}`, ctag);

    // Start initial sync (2 years back)
    const now = new Date();
    const min = new Date(now.getFullYear() - 2, 0, 1);
    const end = new Date(now.getFullYear() + 1, 11, 31);

    await this.set(`sync_state_${channel.id}`, {
      calendarHref: channel.id,
      initialSync: true,
      batchNumber: 1,
    } as SyncState);

    const syncCallback = await this.callback(
      this.syncBatch,
      channel.id,
      true, // initialSync
      1, // batchNumber
      toCalDAVTimeString(min),
      toCalDAVTimeString(end)
    );
    await this.runTask(syncCallback);
  }

  /**
   * Called when a calendar channel is disabled.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    // Cancel scheduled poll
    const pollTask = await this.get<string>(`poll_task_${channel.id}`);
    if (pollTask) {
      await this.cancelTask(pollTask);
      await this.clear(`poll_task_${channel.id}`);
    }

    // Clear all state for this channel
    await this.clear(`sync_enabled_${channel.id}`);
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`ctag_${channel.id}`);
    await this.clear(`etags_${channel.id}`);

    // Clear pending occurrences
    const pendingKeys = await this.tools.store.list(
      "pending_occ:apple-calendar:"
    );
    for (const key of pendingKeys) {
      await this.clear(key);
    }
  }

  // ---- Sync Logic ----

  /**
   * Sync a batch of calendar events.
   */
  async syncBatch(
    calendarHref: string,
    initialSync: boolean,
    batchNumber: number,
    timeRangeStart?: string,
    timeRangeEnd?: string
  ): Promise<void> {
    const client = this.getCalDAV();

    if (batchNumber === 1 && timeRangeStart && timeRangeEnd) {
      // First batch: fetch all events in the time range
      const events = await client.fetchEvents(calendarHref, {
        start: timeRangeStart,
        end: timeRangeEnd,
      });

      // Store etags for incremental sync
      const etagMap: Record<string, string> = {};
      for (const event of events) {
        etagMap[event.href] = event.etag;
      }
      await this.set(`etags_${calendarHref}`, etagMap);

      // Process events in batches
      await this.processCalDAVEvents(
        events.slice(0, 50),
        calendarHref,
        initialSync
      );

      if (events.length > 50) {
        // Store remaining hrefs for next batches
        const remainingHrefs = events.slice(50).map((e) => e.href);
        await this.set(`sync_state_${calendarHref}`, {
          calendarHref,
          initialSync,
          batchNumber: batchNumber + 1,
          pendingHrefs: remainingHrefs,
        } as SyncState);

        const nextBatch = await this.callback(
          this.syncBatchContinue,
          calendarHref,
          initialSync,
          batchNumber + 1
        );
        await this.runTask(nextBatch);
      } else {
        await this.finishSync(calendarHref, initialSync);
      }
    }
  }

  /**
   * Continue processing remaining events using multiget.
   */
  async syncBatchContinue(
    calendarHref: string,
    initialSync: boolean,
    batchNumber: number
  ): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${calendarHref}`);
    if (!state?.pendingHrefs?.length) {
      await this.finishSync(calendarHref, initialSync);
      return;
    }

    const client = this.getCalDAV();
    const batch = state.pendingHrefs.slice(0, 50);
    const remaining = state.pendingHrefs.slice(50);

    const events = await client.fetchEventsByHref(calendarHref, batch);
    await this.processCalDAVEvents(events, calendarHref, initialSync);

    if (remaining.length > 0) {
      await this.set(`sync_state_${calendarHref}`, {
        calendarHref,
        initialSync,
        batchNumber: batchNumber + 1,
        pendingHrefs: remaining,
      } as SyncState);

      const nextBatch = await this.callback(
        this.syncBatchContinue,
        calendarHref,
        initialSync,
        batchNumber + 1
      );
      await this.runTask(nextBatch);
    } else {
      await this.finishSync(calendarHref, initialSync);
    }
  }

  /**
   * Clean up after sync completes and schedule polling.
   */
  private async finishSync(
    calendarHref: string,
    initialSync: boolean
  ): Promise<void> {
    if (initialSync) {
      // Discard buffered occurrences whose masters never appeared
      const pendingKeys = await this.tools.store.list(
        "pending_occ:apple-calendar:"
      );
      for (const key of pendingKeys) {
        await this.clear(key);
      }
    }

    // Update ctag
    const client = this.getCalDAV();
    const ctag = await client.getCalendarCtag(calendarHref);
    if (ctag) await this.set(`ctag_${calendarHref}`, ctag);

    await this.clear(`sync_state_${calendarHref}`);

    // Schedule next poll in 15 minutes
    await this.schedulePoll(calendarHref);
  }

  /**
   * Schedule a poll for changes in 15 minutes.
   */
  private async schedulePoll(calendarHref: string): Promise<void> {
    const enabled = await this.get<boolean>(`sync_enabled_${calendarHref}`);
    if (!enabled) return;

    const pollCallback = await this.callback(this.pollForChanges, calendarHref);
    const taskToken = await this.runTask(pollCallback, {
      runAt: new Date(Date.now() + 15 * 60 * 1000),
    });
    if (taskToken) {
      await this.set(`poll_task_${calendarHref}`, taskToken);
    }
  }

  /**
   * Poll for changes using ctag comparison.
   */
  async pollForChanges(calendarHref: string): Promise<void> {
    const enabled = await this.get<boolean>(`sync_enabled_${calendarHref}`);
    if (!enabled) return;

    try {
      const client = this.getCalDAV();
      const currentCtag = await client.getCalendarCtag(calendarHref);
      const storedCtag = await this.get<string>(`ctag_${calendarHref}`);

      if (currentCtag && currentCtag !== storedCtag) {
        // Calendar has changed — run incremental sync
        await this.startIncrementalSync(calendarHref);
      } else {
        // No changes — just schedule next poll
        await this.schedulePoll(calendarHref);
      }
    } catch (error) {
      console.error(`Poll failed for calendar ${calendarHref}:`, error);
      // Schedule next poll even on failure
      await this.schedulePoll(calendarHref);
    }
  }

  /**
   * Incremental sync: compare etags to find changed/new/deleted events.
   */
  private async startIncrementalSync(calendarHref: string): Promise<void> {
    const client = this.getCalDAV();

    // Get current etags
    const currentEtags = await client.getEventEtags(calendarHref);
    const storedEtags =
      (await this.get<Record<string, string>>(`etags_${calendarHref}`)) || {};

    // Find new/changed events
    const changedHrefs: string[] = [];
    const newEtagMap: Record<string, string> = {};

    for (const [href, etag] of currentEtags) {
      newEtagMap[href] = etag;
      if (!storedEtags[href] || storedEtags[href] !== etag) {
        changedHrefs.push(href);
      }
    }

    // Find deleted events
    const deletedHrefs: string[] = [];
    for (const href of Object.keys(storedEtags)) {
      if (!currentEtags.has(href)) {
        deletedHrefs.push(href);
      }
    }

    // Archive deleted events
    if (deletedHrefs.length > 0) {
      // We need to find the UIDs for deleted events from stored state
      // Since we don't store href→UID mapping, archive by channel
      await this.tools.integrations.archiveLinks({
        channelId: calendarHref,
        meta: { syncProvider: "apple", syncableId: calendarHref },
      });
    }

    // Fetch and process changed events
    if (changedHrefs.length > 0) {
      const events = await client.fetchEventsByHref(calendarHref, changedHrefs);
      await this.processCalDAVEvents(events, calendarHref, false);
    }

    // Update stored etags and ctag
    await this.set(`etags_${calendarHref}`, newEtagMap);
    const ctag = await client.getCalendarCtag(calendarHref);
    if (ctag) await this.set(`ctag_${calendarHref}`, ctag);

    // Schedule next poll
    await this.schedulePoll(calendarHref);
  }

  // ---- Event Processing ----

  /**
   * Process CalDAV events (parse ICS and save as links).
   */
  private async processCalDAVEvents(
    events: CalDAVEvent[],
    calendarHref: string,
    initialSync: boolean
  ): Promise<void> {
    for (const caldavEvent of events) {
      try {
        const icsEvents = parseICSEvents(caldavEvent.icsData);

        for (const icsEvent of icsEvents) {
          if (icsEvent.recurrenceId) {
            await this.processEventInstance(
              icsEvent,
              calendarHref,
              initialSync,
              caldavEvent.href
            );
          } else {
            await this.processEvent(
              icsEvent,
              calendarHref,
              initialSync,
              caldavEvent.href
            );
          }
        }
      } catch (error) {
        console.error(
          `Error processing CalDAV event ${caldavEvent.href}:`,
          error
        );
      }
    }
  }

  /**
   * Process a single ICS event (master or standalone) into a Plot link.
   */
  private async processEvent(
    icsEvent: ICSEvent,
    calendarHref: string,
    initialSync: boolean,
    eventHref?: string
  ): Promise<void> {
    const source = `apple-calendar:${icsEvent.uid}`;
    const isCancelled = icsEvent.status === "CANCELLED";

    // On initial sync, skip cancelled events
    if (initialSync && isCancelled) return;

    // Parse start/end
    const start = parseICSDateTime(icsEvent.dtstart);
    const end = icsEvent.dtend ? parseICSDateTime(icsEvent.dtend) : null;
    const isAllDay = typeof start === "string";

    // Author from organizer
    const authorContact: NewContact | undefined = icsEvent.organizer
      ? {
          email: icsEvent.organizer.email,
          name: icsEvent.organizer.name ?? undefined,
        }
      : undefined;

    // Handle cancelled events
    if (isCancelled) {
      const cancelNote = {
        key: "cancellation" as const,
        content: icsEvent.organizer?.name
          ? `${icsEvent.organizer.name} cancelled this event.`
          : "This event was cancelled.",
        contentType: "text" as const,
        created: icsEvent.lastModified
          ? parseICSDateTimeToDate(icsEvent.lastModified)
          : new Date(),
      };

      const link: NewLinkWithNotes = {
        source,
        type: "event",
        title: icsEvent.summary ?? undefined,
        status: "Cancelled",
        preview: "Cancelled",
        channelId: calendarHref,
        meta: {
          uid: icsEvent.uid,
          eventHref: eventHref || null,
          syncProvider: "apple",
          syncableId: calendarHref,
        },
        notes: [cancelNote],
        schedules: [
          {
            start: start instanceof Date ? start : new Date(),
            archived: true,
          },
        ],
        ...(initialSync ? { unread: false } : {}),
        ...(initialSync ? { archived: false } : {}),
      };

      await this.tools.integrations.saveLink(link);
      return;
    }

    // Build schedule
    const schedule: Omit<NewSchedule, "threadId"> = {
      start,
      end: end ?? null,
    };

    // Handle recurrence for master events
    if (icsEvent.rrule) {
      schedule.recurrenceRule = icsEvent.rrule;

      const recurrenceCount = parseRRuleCount(icsEvent.rrule);
      if (recurrenceCount) {
        schedule.recurrenceCount = recurrenceCount;
      } else {
        const recurrenceUntil = parseRRuleEnd(icsEvent.rrule);
        if (recurrenceUntil) {
          schedule.recurrenceUntil = recurrenceUntil;
        }
      }

      if (icsEvent.exdates.length > 0) {
        schedule.recurrenceExdates = icsEvent.exdates;
      }
    }

    // Build schedule occurrences from RDATEs
    let scheduleOccurrences: NewScheduleOccurrence[] | undefined;
    if (icsEvent.rdates.length > 0) {
      scheduleOccurrences = icsEvent.rdates.map((rdate) => ({
        occurrence: rdate,
        start: rdate,
      }));
    }

    // Build attendee contacts on the base schedule so client-generated
    // recurring occurrences inherit attendee data (needed for RSVP buttons).
    // Per-occurrence overrides with their own contacts take precedence.
    const validAttendees = icsEvent.attendees.filter((a) => a.email);
    let scheduleContacts: NewScheduleContact[] | undefined;
    if (validAttendees.length > 0) {
      scheduleContacts = validAttendees.map((att) => ({
        contact: { email: att.email, name: att.name ?? undefined },
        status:
          att.partstat === "ACCEPTED"
            ? ("attend" as const)
            : att.partstat === "DECLINED"
            ? ("skip" as const)
            : null,
        role:
          att.role === "CHAIR"
            ? ("organizer" as const)
            : att.role === "OPT-PARTICIPANT"
            ? ("optional" as const)
            : ("required" as const),
      }));
      schedule.contacts = scheduleContacts;
    }

    // Build actions (conferencing links from description/location)
    const actions: Action[] = [];
    const seenUrls = new Set<string>();

    if (icsEvent.location) {
      extractConferencingUrls(icsEvent.location, actions, seenUrls);
    }
    if (icsEvent.description) {
      extractConferencingUrls(icsEvent.description, actions, seenUrls);
    }
    if (icsEvent.url) {
      actions.push({
        type: ActionType.external,
        title: "Open Link",
        url: icsEvent.url,
      });
    }

    // Build description note
    const hasDescription =
      icsEvent.description && icsEvent.description.trim().length > 0;

    const attendeeMentions: NewContact[] = [];
    if (authorContact) attendeeMentions.push(authorContact);
    for (const att of validAttendees) {
      attendeeMentions.push({ email: att.email, name: att.name ?? undefined });
    }

    const descriptionNote = hasDescription
      ? {
          key: "description",
          content: icsEvent.description!,
          contentType: "text" as const,
          created: icsEvent.created
            ? parseICSDateTimeToDate(icsEvent.created)
            : undefined,
          ...(authorContact ? { author: authorContact } : {}),
          ...(attendeeMentions.length > 0
            ? { mentions: attendeeMentions }
            : {}),
        }
      : null;

    const notes = descriptionNote
      ? [descriptionNote]
      : attendeeMentions.length > 0
      ? [{ key: "participants", content: null, mentions: attendeeMentions }]
      : [];

    // Skip all-day events without a type (matching Google Calendar pattern)
    if (isAllDay && !isCancelled) {
      // All-day events are still synced, they just don't get type "event"
    }

    const link: NewLinkWithNotes = {
      source,
      type: "event",
      title: icsEvent.summary || "",
      status:
        icsEvent.status === "CONFIRMED"
          ? "Confirmed"
          : icsEvent.status === "TENTATIVE"
          ? "Tentative"
          : "Confirmed",
      access: "private",
      accessContacts: attendeeMentions,
      created: icsEvent.created
        ? parseICSDateTimeToDate(icsEvent.created)
        : undefined,
      author: authorContact,
      channelId: calendarHref,
      meta: {
        uid: icsEvent.uid,
        eventHref: eventHref || null,
        syncProvider: "apple",
        syncableId: calendarHref,
        location: icsEvent.location || null,
      },
      sourceUrl: icsEvent.url ?? null,
      actions: actions.length > 0 ? actions : undefined,
      notes,
      preview: hasDescription ? icsEvent.description!.slice(0, 200) : null,
      schedules: [schedule],
      scheduleOccurrences,
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };

    // Merge buffered occurrences from initial sync
    const pendingKey = `pending_occ:${source}`;
    const pendingOccurrences = await this.get<PendingOccurrence[]>(pendingKey);
    if (pendingOccurrences) {
      link.scheduleOccurrences = [
        ...(link.scheduleOccurrences || []),
        ...pendingOccurrences.map((p) => p.occurrence),
      ];
      await this.clear(pendingKey);
    }

    await this.tools.integrations.saveLink(link);
  }

  /**
   * Process a recurring event instance (RECURRENCE-ID) as an occurrence override.
   */
  private async processEventInstance(
    icsEvent: ICSEvent,
    calendarHref: string,
    initialSync: boolean,
    _eventHref?: string
  ): Promise<void> {
    if (!icsEvent.recurrenceId) return;

    const originalStart = parseICSDateTime(icsEvent.recurrenceId);
    const masterSource = `apple-calendar:${icsEvent.uid}`;

    // Handle cancelled instances
    if (icsEvent.status === "CANCELLED") {
      const start = parseICSDateTime(icsEvent.dtstart);
      const end = icsEvent.dtend ? parseICSDateTime(icsEvent.dtend) : null;

      const cancelledOccurrence: NewScheduleOccurrence = {
        occurrence:
          originalStart instanceof Date
            ? originalStart
            : new Date(originalStart),
        start: start instanceof Date ? start : new Date(start),
        end: end,
        archived: true,
      };

      if (initialSync) {
        const pendingKey = `pending_occ:${masterSource}`;
        const existing =
          (await this.get<PendingOccurrence[]>(pendingKey)) || [];
        existing.push({ occurrence: cancelledOccurrence, cancelled: true });
        await this.set(pendingKey, existing);
        return;
      }

      const occurrenceUpdate: NewLinkWithNotes = {
        type: "event",
        title: undefined,
        source: masterSource,
        channelId: calendarHref,
        meta: { syncProvider: "apple", syncableId: calendarHref },
        scheduleOccurrences: [cancelledOccurrence],
        notes: [],
      };

      await this.tools.integrations.saveLink(occurrenceUpdate);
      return;
    }

    // Build contacts from attendees for this occurrence
    const validAttendees = icsEvent.attendees.filter((a) => a.email);
    const contacts: NewScheduleContact[] | undefined =
      validAttendees.length > 0
        ? validAttendees.map((att) => ({
            contact: { email: att.email, name: att.name ?? undefined },
            status:
              att.partstat === "ACCEPTED"
                ? ("attend" as const)
                : att.partstat === "DECLINED"
                ? ("skip" as const)
                : null,
            role:
              att.role === "CHAIR"
                ? ("organizer" as const)
                : att.role === "OPT-PARTICIPANT"
                ? ("optional" as const)
                : ("required" as const),
          }))
        : undefined;

    const instanceStart = parseICSDateTime(icsEvent.dtstart);
    const instanceEnd = icsEvent.dtend
      ? parseICSDateTime(icsEvent.dtend)
      : null;

    const occurrence: NewScheduleOccurrence = {
      occurrence:
        originalStart instanceof Date ? originalStart : new Date(originalStart),
      start: instanceStart,
      contacts,
      ...(initialSync ? { unread: false } : {}),
    };

    if (instanceEnd !== undefined && instanceEnd !== null) {
      occurrence.end = instanceEnd;
    }

    // During initial sync, buffer for merging with master
    if (initialSync) {
      const pendingKey = `pending_occ:${masterSource}`;
      const existing = (await this.get<PendingOccurrence[]>(pendingKey)) || [];
      existing.push({ occurrence, cancelled: false });
      await this.set(pendingKey, existing);
      return;
    }

    // Incremental sync: save immediately
    const occurrenceUpdate: NewLinkWithNotes = {
      type: "event",
      title: undefined,
      source: masterSource,
      channelId: calendarHref,
      meta: { syncProvider: "apple", syncableId: calendarHref },
      scheduleOccurrences: [occurrence],
      notes: [],
    };

    await this.tools.integrations.saveLink(occurrenceUpdate);
  }

  // ---- RSVP Write-Back ----

  /**
   * Called when a user changes their RSVP status in Plot.
   * Updates the ATTENDEE PARTSTAT in the CalDAV event via PUT.
   */
  async onScheduleContactUpdated(
    thread: Thread,
    _scheduleId: string,
    _contactId: ActorId,
    status: ScheduleContactStatus | null,
    _actor: Actor
  ): Promise<void> {
    const meta = thread.meta as Record<string, unknown> | null;
    const linkSource = meta?.linkSource as string | null;
    const calendarHref = meta?.syncableId as string | null;
    const eventHref = meta?.eventHref as string | null;

    if (!linkSource || !calendarHref || !eventHref) return;

    // The connector user's email is the Apple ID
    const appleId = this.tools.options.appleId as string;
    if (!appleId) return;

    // Map Plot status to CalDAV PARTSTAT
    const partstat =
      status === "attend"
        ? "ACCEPTED"
        : status === "skip"
        ? "DECLINED"
        : "NEEDS-ACTION";

    try {
      await this.updateRSVP(calendarHref, eventHref, appleId, partstat);
    } catch (error) {
      console.error("[RSVP Sync] Failed to sync RSVP to Apple Calendar", {
        eventHref,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  /**
   * Update RSVP status for the connector user on a CalDAV event.
   * Fetches the event ICS, modifies the ATTENDEE PARTSTAT, and PUTs it back.
   */
  private async updateRSVP(
    _calendarHref: string,
    eventHref: string,
    email: string,
    partstat: string
  ): Promise<void> {
    const client = this.getCalDAV();

    // Fetch current ICS
    const icsData = await client.fetchEventICS(eventHref);
    if (!icsData) {
      throw new Error(`Event not found: ${eventHref}`);
    }

    // Update the attendee's PARTSTAT
    const updatedICS = updateAttendeePartstat(icsData, email, partstat);
    if (!updatedICS) {
      console.warn(
        `[RSVP Sync] User ${email} is not an attendee of event ${eventHref}`
      );
      return;
    }

    // PUT the updated ICS back
    const success = await client.updateEventICS(eventHref, updatedICS);
    if (!success) {
      throw new Error(`Failed to update event: ${eventHref}`);
    }
  }
}

// ---- Helpers ----

/**
 * Parse a raw ICS datetime string to a Date (for created/lastModified fields).
 */
function parseICSDateTimeToDate(value: string): Date {
  const d = value.trim();
  if (/^\d{8}T\d{6}Z?$/.test(d)) {
    const year = d.slice(0, 4);
    const month = d.slice(4, 6);
    const day = d.slice(6, 8);
    const hour = d.slice(9, 11);
    const minute = d.slice(11, 13);
    const second = d.slice(13, 15);
    return new Date(`${year}-${month}-${day}T${hour}:${minute}:${second}Z`);
  }
  return new Date(d);
}

/**
 * Detect conferencing provider from a URL.
 */
function detectConferencingProvider(url: string): ConferencingProvider | null {
  const lowerUrl = url.toLowerCase();

  if (lowerUrl.includes("zoom.us")) return ConferencingProvider.zoom;
  if (
    lowerUrl.includes("teams.microsoft.com") ||
    lowerUrl.includes("teams.live.com")
  )
    return ConferencingProvider.microsoftTeams;
  if (lowerUrl.includes("webex.com")) return ConferencingProvider.webex;
  if (lowerUrl.includes("meet.google.com"))
    return ConferencingProvider.googleMeet;

  return null;
}

/**
 * Extract conferencing URLs from text and add to actions array.
 */
function extractConferencingUrls(
  text: string,
  actions: Action[],
  seenUrls: Set<string>
): void {
  const urlRegex = /https?:\/\/[^\s<>"{}|\\^`\[\]]+/gi;
  const matches = text.match(urlRegex);
  if (!matches) return;

  for (const url of matches) {
    const provider = detectConferencingProvider(url);
    if (provider && !seenUrls.has(url)) {
      seenUrls.add(url);
      actions.push({
        type: ActionType.conferencing,
        url,
        provider,
      });
    }
  }
}

export default AppleCalendar;
