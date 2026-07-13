/**
 * Reusable calendar sync functions extracted from OutlookCalendar.
 *
 * These functions implement the initial backfill state machine (quick pass +
 * full pass), the MS Graph subscription (watch) lifecycle, the incremental
 * webhook-driven sync, and the RSVP write-back — all without any
 * connector-level scheduling. They accept an OutlookCalendarSyncHost instead
 * of `this` so they can be invoked from both the standalone OutlookCalendar
 * connector and a combined Outlook connector (which wraps `this` in a
 * key-namespaced proxy).
 *
 * Scheduling (this.callback / this.runTask / this.scheduleRecurring) is
 * intentionally absent here. Each function that needs to schedule the next
 * batch/renewal returns a descriptor that tells the caller what to do next;
 * the caller owns the scheduling.
 */

import {
  type Action,
  ActionType,
  type ActorId,
  ConferencingProvider,
  type ContentType,
  type NewContact,
  type NewLinkWithNotes,
  type Thread,
} from "@plotday/twister";
import type { ScheduleContactStatus } from "@plotday/twister/schedule";
import type {
  NewScheduleContact,
  NewScheduleOccurrence,
} from "@plotday/twister/schedule";

import {
  fromMsDate,
  GraphApi,
  type OutlookEvent,
  type SyncState,
  syncOutlookCalendar,
  transformOutlookEvent,
} from "./graph-api";

/**
 * A cancellation is "fully in the past" when the cancelled event has already
 * ended. Surfacing it adds a "cancelled" note (or bumps the master thread for a
 * cancelled occurrence) and flips the thread unread for a meeting that already
 * happened — noise, especially when the cancellation syncs in long after the
 * fact. Events that have started but not yet finished (ongoing) and future
 * events are kept, so the user still learns an upcoming/in-progress meeting
 * won't happen.
 *
 * The connector fetches events in UTC (via the Graph `Prefer` header), so
 * `fromMsDate` yields correct instants. End is taken from the event's explicit
 * `end`, else its `start`, else the occurrence's `originalStart`. An event with
 * no time data — e.g. a delta-removed (`@removed`) event, which Graph returns
 * with only an id — cannot be judged past and is kept.
 */
export function cancellationIsForPastEventFn(
  event: OutlookEvent,
  now: Date = new Date()
): boolean {
  if (event.end?.dateTime) return fromMsDate(event.end)! < now;
  const start = event.start?.dateTime
    ? fromMsDate(event.start)!
    : event.originalStart
    ? new Date(event.originalStart)
    : null;
  if (!start) return false;
  return start < now;
}

// ---------------------------------------------------------------------------
// Host interface
// ---------------------------------------------------------------------------

/**
 * Minimal interface that a sync host must satisfy. Both OutlookCalendar (using
 * `this` directly) and a combined Outlook connector (using a key-namespaced
 * proxy) implement this.
 */
export interface OutlookCalendarSyncHost {
  /** Persist a value under a connector-scoped key. */
  set(key: string, value: unknown): Promise<void>;
  /** Retrieve a previously persisted value. Returns null if absent. */
  get<T>(key: string): Promise<T | null>;
  /** Delete a persisted value. */
  clear(key: string): Promise<void>;

  tools: {
    integrations: {
      /** Read the OAuth token for a channel. */
      get(
        channelId: string
      ): Promise<{ token: string; scopes: string[] } | null>;
      /** Persist a batch of links (upsert by source). */
      saveLinks(links: NewLinkWithNotes[]): Promise<unknown>;
      /** Signal that the initial backfill for a channel has finished. */
      channelSyncCompleted(channelId: string): Promise<void>;
    };
    store: {
      /** Try to acquire a named lock. Returns true if acquired. */
      acquireLock(key: string, ttlMs: number): Promise<boolean>;
      /** Release a named lock. */
      releaseLock(key: string): Promise<void>;
      /** List all persisted keys that start with the given prefix. */
      list(prefix: string): Promise<string[]>;
    };
  };
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * Lock TTL covering the worst-case full backfill (quick + full pass). The
 * framework releases the lock automatically after this window even if a
 * worker crashes, so no stuck-sync recovery is needed.
 */
export const SYNC_LOCK_TTL_MS = 2 * 60 * 60 * 1000;

/**
 * Renew subscription this far before expiry. MS Graph caps calendar
 * subscriptions at ~3 days; without renewal every connection's webhook
 * silently dies after 72 hours.
 */
export const RENEWAL_LEAD_MS = 24 * 60 * 60 * 1000;

/**
 * Maximum subscription lifetime allowed by MS Graph for calendar resources.
 * Used when creating/renewing subscriptions.
 */
export const SUBSCRIPTION_DURATION_DAYS = 3;

// ---------------------------------------------------------------------------
// State / descriptor types
// ---------------------------------------------------------------------------

export type WatchState = {
  subscriptionId: string;
  calendarId: string;
  expiry: Date;
};

/**
 * Return type for {@link initOutlookCalendarFn} and {@link startSyncFn}.
 *
 * - `next`: schedule the first sync batch with these parameters.
 * - `done`: skip — token missing or lock not acquired.
 */
export type OutlookInitResult =
  | { next: { calendarId: string; initialSync: boolean; batchNumber: number } }
  | { done: true };

/**
 * Return type for {@link syncOutlookBatchFn}.
 *
 * - `next`: schedule another batch with these parameters.
 * - `done`: no more batches; the caller should release any held resources
 *   (already released internally by the function).
 */
export type SyncOutlookBatchResult =
  | { next: { calendarId: string; initialSync: boolean; batchNumber: number } }
  | { done: true };

/**
 * Return type for {@link scheduleSubscriptionRenewalFn}.
 *
 * - `immediate`: the renewal window has already passed; the caller should
 *   renew the watch immediately instead of scheduling.
 * - `{ firstRunAt, intervalMs }`: the caller should schedule a recurring
 *   renewal with these parameters.
 *
 * Returns `null` when no watch data is found (nothing to schedule).
 */
export type SubscriptionRenewalSchedule =
  | { immediate: true }
  | { firstRunAt: Date; intervalMs: number };

/**
 * Return type for {@link renewOutlookWatchFn}.
 *
 * - `renewed`: the PATCH renewal succeeded; the caller should schedule the
 *   next proactive renewal (via {@link scheduleSubscriptionRenewalFn}).
 * - `recreate`: the PATCH renewal failed; the caller should re-run
 *   `setupOutlookWatch` (which re-creates the subscription AND re-schedules
 *   the next renewal).
 * - `done`: nothing to do (missing watch data, missing token, or an
 *   unexpected error already logged internally).
 */
export type RenewOutlookWatchResult =
  | { renewed: true }
  | { recreate: true }
  | { done: true };

/**
 * Return type for {@link setupOutlookWatchFn}.
 *
 * - `skipped`: webhook URL is localhost, or the watch creation failed —
 *   no renewal should be scheduled.
 * - `ok`: subscription created successfully; caller should schedule renewal.
 */
export type SetupOutlookWatchResult = { skipped: true } | { ok: true };

/**
 * Return type for {@link startIncrementalSyncFn}.
 *
 * - `done`: lock not acquired, token missing, or watch data missing — no
 *   batch to schedule.
 * - `next`: schedule the first incremental batch.
 */
export type StartIncrementalSyncResult =
  | { done: true }
  | { next: { calendarId: string; initialSync: boolean; batchNumber: number } };

/**
 * Parameters extracted from a thread for an RSVP write-back.
 *
 * `null` when the thread lacks the required calendar metadata.
 */
export type RSVPParams = {
  calendarId: string;
  eventId: string;
  outlookStatus: "accepted" | "declined" | "tentativelyAccepted";
} | null;

// ---------------------------------------------------------------------------
// Pure helpers (no host state)
// ---------------------------------------------------------------------------

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
export function buildEventSources(opts: {
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
 * De-duplicate a note/link contact roster by email (case-insensitive),
 * keeping the first occurrence. The organizer is both surfaced via
 * `event.organizer` (used to seed the roster first, so its `name` wins) and,
 * commonly, listed again in `event.attendees` — without this, the
 * message-model roster would carry the same person twice.
 */
function dedupeContactsByEmail(contacts: NewContact[]): NewContact[] {
  const seen = new Set<string>();
  const result: NewContact[] = [];
  for (const contact of contacts) {
    const key = contact.email?.toLowerCase();
    if (key) {
      if (seen.has(key)) continue;
      seen.add(key);
    }
    result.push(contact);
  }
  return result;
}

/**
 * Extracts the calendar id, event id, and mapped Outlook RSVP status from a
 * Plot thread's metadata. Returns `null` when the required fields are absent
 * (no-op case).
 *
 * This is a pure helper — no async operations or side effects.
 */
export function extractRSVPParamsFn(
  thread: Thread,
  status: ScheduleContactStatus | null
): RSVPParams {
  const meta = thread.meta as Record<string, unknown> | null;
  const calendarId = meta?.syncableId as string | null;
  // Per-mailbox Outlook event id is stored in meta.eventId by
  // transformOutlookEvent. We can't derive it from `source` anymore,
  // because the source format has been qualified with calendarId
  // (`outlook-calendar:<calendarId>:<eventId>`) for cross-user dedup.
  const eventId = meta?.eventId as string | null;

  if (!eventId || !calendarId) return null;

  const outlookStatus =
    status === "attend"
      ? ("accepted" as const)
      : status === "skip"
      ? ("declined" as const)
      : ("tentativelyAccepted" as const);

  return { calendarId, eventId, outlookStatus };
}

// ---------------------------------------------------------------------------
// Account helpers (mechanical this.X → host.X)
// ---------------------------------------------------------------------------

/**
 * Build a GraphApi instance authenticated for the given calendar channel.
 * Throws "No Microsoft authentication token available" if the token is absent.
 */
export async function getApiFn(
  host: OutlookCalendarSyncHost,
  calendarId: string
): Promise<GraphApi> {
  const token = await host.tools.integrations.get(calendarId);
  if (!token) {
    throw new Error("No Microsoft authentication token available");
  }
  return new GraphApi(token.token);
}

/**
 * Non-throwing variant of getApiFn(): logs a warning and returns null
 * when the auth token is missing. Used by queued tasks so a cleared
 * token doesn't turn into an infinite retry loop. Callers remain
 * responsible for releasing any held lock and clearing sync state on
 * null (cleanup varies per call site).
 */
export async function tryGetApiFn(
  host: OutlookCalendarSyncHost,
  calendarId: string,
  label: string
): Promise<GraphApi | null> {
  const token = await host.tools.integrations.get(calendarId);
  if (!token) {
    console.warn(
      `Auth token missing for calendar ${calendarId} during ${label}, skipping`
    );
    return null;
  }
  return new GraphApi(token.token);
}

export async function getUserEmailFn(
  host: OutlookCalendarSyncHost,
  calendarId: string
): Promise<string> {
  const api = await getApiFn(host, calendarId);
  const data = (await api.call(
    "GET",
    "https://graph.microsoft.com/v1.0/me"
  )) as { mail?: string; userPrincipalName?: string };

  return data.mail || data.userPrincipalName || "";
}

export async function ensureUserIdentityFn(
  host: OutlookCalendarSyncHost,
  calendarId: string
): Promise<string> {
  // Check if we already have the user email stored
  const stored = await host.get<string>("user_email");
  if (stored) {
    return stored;
  }

  // Fetch user email from Microsoft Graph
  const email = await getUserEmailFn(host, calendarId);

  // Store for future use
  await host.set("user_email", email);
  return email;
}

export async function getCalendarsFn(
  host: OutlookCalendarSyncHost,
  calendarId: string
): Promise<import("./channels").Calendar[]> {
  const api = await getApiFn(host, calendarId);
  return await api.getCalendars();
}

// ---------------------------------------------------------------------------
// Extracted helper functions (mechanical this.X → host.X)
// ---------------------------------------------------------------------------

/**
 * Stamp the first time the connector observes some opaque key, and reuse
 * that timestamp on every subsequent observation. Used for description note
 * `created` timestamps: Outlook's `lastModifiedDateTime` bumps on any edit
 * (e.g. attendee changes), so re-using it as `created` would drag the
 * description note forward in the activity feed on unrelated updates.
 * `firstSeenAt` anchors `created` to the first observation per content hash.
 */
export async function firstSeenAtFn(
  host: OutlookCalendarSyncHost,
  storeKey: string
): Promise<Date> {
  const existing = await host.get<string>(storeKey);
  if (existing) return new Date(existing);
  const now = new Date();
  await host.set(storeKey, now.toISOString());
  return now;
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
export async function clearBuffersFn(
  host: OutlookCalendarSyncHost,
  calendarId: string
): Promise<void> {
  const pendingKeys = await host.tools.store.list(
    `pending_occ:outlook-calendar:${calendarId}:`
  );
  for (const key of pendingKeys) {
    await host.clear(key);
  }
  const seenMasterKeys = await host.tools.store.list(
    `seen_master:outlook-calendar:${calendarId}:`
  );
  for (const key of seenMasterKeys) {
    await host.clear(key);
  }
}

/**
 * Transform a recurring event instance (occurrence or exception)
 * into either an occurrence-only {@link NewLinkWithNotes} (for the
 * caller's batched saveLinks), or `null` when the occurrence is
 * instead buffered to `pending_occ:` storage for cross-batch
 * merging during initial sync. Never saves directly.
 */
export async function prepareEventInstanceFn(
  host: OutlookCalendarSyncHost,
  event: OutlookEvent,
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
      await host.set(pendingKey, cancelledOccurrence);
      console.log(
        `[OutlookCalendar] buffered cancelled instance: ` +
          `master=${masterCanonicalUrl} ` +
          `originalStart=${new Date(originalStart).toISOString()} ` +
          `(calendar=${calendarId})`
      );
      return null;
    }

    // Drop the cancellation when the occurrence has already ended — bumping the
    // master thread for a past occurrence's cancellation is just noise.
    if (cancellationIsForPastEventFn(event)) {
      console.log(
        `[OutlookCalendar] skipping cancelled occurrence fully in the past ` +
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
          status:
            attendee.status?.response === "accepted"
              ? ("attend" as const)
              : attendee.status?.response === "declined"
              ? ("skip" as const)
              : null,
          role:
            attendee.type === "required"
              ? ("required" as const)
              : attendee.type === "optional"
              ? ("optional" as const)
              : ("required" as const),
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
    await host.set(pendingKey, occurrence);
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

/**
 * Process Outlook events from a sync batch.
 *
 * Coalesces all events keyed by canonical `source` so a master and
 * any number of its exception instances collapse into a single
 * NewLinkWithNotes. The final saveLinks call makes one cross-runtime
 * RPC for the entire page. Heavy recurring meetings with many
 * exceptions used to fire N+1 saveLink calls; now they fire one.
 */
export async function processOutlookEventsFn(
  host: OutlookCalendarSyncHost,
  events: OutlookEvent[],
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
        // Drop the cancellation when the event has already ended — a past
        // event's cancellation is just noise (and would flip the thread unread
        // for a meeting that already happened). Best-effort: Graph delta
        // returns `@removed` items with only an id, so time data is usually
        // absent and the event is kept (the guard fires only if Graph ever
        // includes start/end on the removal).
        if (cancellationIsForPastEventFn(outlookEvent)) {
          continue;
        }

        // Graph event ids are mailbox-local, so qualify with calendarId
        // to keep source globally unique across users.
        const source = `outlook-calendar:${calendarId}:${outlookEvent.id}`;

        // Roster for the message-model thread: organizer + attendees
        // (mirrors the live-event path's attendeeMentions below). Graph
        // delta returns `@removed` items with only an id in the common
        // case, so organizer/attendees are usually absent here — guard
        // below so we never overwrite the roster the main event sync
        // already established on this link with an empty one.
        const cancelAuthorContact: NewContact | undefined =
          outlookEvent.organizer?.emailAddress?.address
            ? {
                email: outlookEvent.organizer.emailAddress.address,
                name: outlookEvent.organizer.emailAddress.name,
              }
            : undefined;
        const cancelValidAttendees = (outlookEvent.attendees ?? []).filter(
          (att) => att.emailAddress?.address && att.type !== "resource"
        );
        const rawCancelMentions: NewContact[] = [];
        if (cancelAuthorContact) rawCancelMentions.push(cancelAuthorContact);
        for (const att of cancelValidAttendees) {
          if (att.emailAddress?.address) {
            rawCancelMentions.push({
              email: att.emailAddress.address,
              name: att.emailAddress.name,
            });
          }
        }
        const cancelMentions = dedupeContactsByEmail(rawCancelMentions);

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
          ...(cancelMentions.length > 0
            ? { accessContacts: cancelMentions }
            : {}),
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
          // Floor above a bundled email link's default priority (0) so the
          // event link stays primary. Graph's event payload has no reliable
          // self/organizer signal (no `isOrganizer`, no per-attendee `self`),
          // so this is a constant rather than a 100/50 split like Google.
          priority: 1,
          meta: { syncProvider: "microsoft", syncableId: calendarId },
          notes: [cancelNote],
          ...(cancelMentions.length > 0
            ? { access: "private" as const, accessContacts: cancelMentions }
            : {}),
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
        const instanceLink = await prepareEventInstanceFn(
          host,
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
        const contacts: NewScheduleContact[] = validAttendees.map(
          (attendee) => ({
            contact: {
              email: attendee.emailAddress!.address!,
              name: attendee.emailAddress!.name,
            },
            status:
              attendee.status?.response === "accepted"
                ? ("attend" as const)
                : attendee.status?.response === "declined"
                ? ("skip" as const)
                : null,
            role:
              attendee.type === "required"
                ? ("required" as const)
                : attendee.type === "optional"
                ? ("optional" as const)
                : ("required" as const),
          })
        );
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
        ? await firstSeenAtFn(host, `desc_seen:${canonicalUrl}:${descHash}`)
        : undefined;
      // Build attendee contacts for link-level access control (message-model
      // roster: organizer + attendees, deduped by email so the organizer
      // isn't counted twice when Graph also lists them in attendees).
      const rawAttendeeMentions: NewContact[] = [];
      if (authorContact) rawAttendeeMentions.push(authorContact);
      for (const att of validAttendees) {
        if (att.emailAddress?.address) {
          rawAttendeeMentions.push({
            email: att.emailAddress.address,
            name: att.emailAddress.name,
          });
        }
      }
      const attendeeMentions = dedupeContactsByEmail(rawAttendeeMentions);

      const descriptionNote =
        hasDescription && descHash
          ? {
              key: `description-${descHash}`,
              content: descriptionContent,
              contentType: (outlookEvent.body?.contentType === "html"
                ? "html"
                : "text") as ContentType,
              created: descFirstSeen,
              accessContacts: attendeeMentions,
            }
          : null;

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
        // Floor above a bundled email link's default priority (0) so the
        // event link stays primary. Graph's event payload has no reliable
        // self/organizer signal (no `isOrganizer`, no per-attendee `self`),
        // so this is a constant rather than a 100/50 split like Google.
        priority: 1,
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
    const pendingKeys = await host.tools.store.list(pendingPrefix);
    if (pendingKeys.length === 0) continue;
    const merged: NewScheduleOccurrence[] = [
      ...(link.scheduleOccurrences || []),
    ];
    for (const key of pendingKeys) {
      const pending = await host.get<NewScheduleOccurrence>(key);
      if (pending) {
        merged.push(pending);
        drainedTotal += 1;
      }
      await host.clear(key);
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
      await host.set(`seen_master:${source}`, true);
    }
  }

  // Single batched save for the whole page. Collapses what used to
  // be one saveLink RPC per event (and one per exception instance
  // on heavy recurring meetings) into a single cross-runtime call.
  const batch = Array.from(linksBySource.values());
  if (batch.length > 0) {
    await host.tools.integrations.saveLinks(batch);
  }
}

// ---------------------------------------------------------------------------
// Main extracted sync functions
// ---------------------------------------------------------------------------

/**
 * Extracted calendar initialization: acquires the sync lock and sets the
 * initial quick-pass SyncState.
 *
 * Does NOT set up the push webhook (watch setup stays on the concrete
 * connector so it can reference its own callback methods) and does NOT queue
 * the first batch (the caller schedules it).
 *
 * Returns `{ done: true }` when the token is missing or the lock is not
 * acquired. Otherwise returns `{ next }` with the parameters for the first
 * syncOutlookBatch.
 */
export async function initOutlookCalendarFn(
  host: OutlookCalendarSyncHost,
  calendarId: string
): Promise<OutlookInitResult> {
  // Auth-token presence check up front: getApi() throws if the token
  // was cleared, and as a queued task that throw becomes a retry loop.
  // Skip cleanly instead.
  const api = await tryGetApiFn(host, calendarId, "initCalendar");
  if (!api) {
    return { done: true };
  }

  // Acquire sync lock. Self-expires after SYNC_LOCK_TTL_MS so a crashed
  // worker can't wedge sync forever. Bails if another sync is in flight.
  const acquired = await host.tools.store.acquireLock(
    `sync_${calendarId}`,
    SYNC_LOCK_TTL_MS
  );
  if (!acquired) {
    return { done: true };
  }

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

  await host.set(`outlook_sync_state_${calendarId}`, initialState);

  return {
    next: { calendarId, initialSync: true, batchNumber: 1 },
  };
}

/**
 * Extracted manual-start sync: acquires the sync lock and sets the initial
 * SyncState honoring the optional timeMin/timeMax window.
 *
 * Does NOT set up the push webhook (watch setup stays on the concrete
 * connector) and does NOT queue the first batch (the caller schedules it).
 *
 * Returns `{ done: true }` when the lock is not acquired. Otherwise returns
 * `{ next }` with the parameters for the first syncOutlookBatch.
 */
export async function startSyncFn(
  host: OutlookCalendarSyncHost,
  options: {
    calendarId: string;
    timeMin?: Date | null;
    timeMax?: Date | null;
  }
): Promise<OutlookInitResult> {
  const { calendarId, timeMin, timeMax } = options;

  const acquired = await host.tools.store.acquireLock(
    `sync_${calendarId}`,
    SYNC_LOCK_TTL_MS
  );
  if (!acquired) {
    return { done: true };
  }

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
  await host.set(`outlook_sync_state_${calendarId}`, {
    calendarId,
    min,
    max,
    sequence: 1,
  } as SyncState);

  return {
    next: { calendarId, initialSync: true, batchNumber: 1 },
  };
}

/**
 * Extracted teardown: stops the MS Graph subscription, clears sync state,
 * releases the lock, and clears the pending/seen buffers.
 *
 * Does NOT cancel the scheduled renewal task (that requires the connector's
 * `cancelScheduledTask`); the caller handles it.
 */
export async function stopSyncFn(
  host: OutlookCalendarSyncHost,
  calendarId: string
): Promise<void> {
  // Stop webhook subscription (best effort)
  const watchData = await host.get<WatchState>(`outlook_watch_${calendarId}`);
  if (watchData?.subscriptionId) {
    try {
      const api = await getApiFn(host, calendarId);
      await api.deleteSubscription(watchData.subscriptionId);
    } catch (error) {
      console.error("Failed to delete Outlook subscription:", error);
      // Continue to clear local state even if API call fails
    }
    await host.clear(`outlook_watch_${calendarId}`);
  }

  // Clear sync state and release the framework-managed lock.
  await host.clear(`outlook_sync_state_${calendarId}`);
  await host.tools.store.releaseLock(`sync_${calendarId}`);

  // Clear any leftover `pending_occ:` / `seen_master:` markers so a
  // future re-enable starts from a clean slate (no stale buffers from
  // a crashed run sitting around to corrupt the next orphan flush).
  await clearBuffersFn(host, calendarId);
}

/**
 * Extracted backfill state machine. Processes one batch of calendar events
 * and returns a descriptor for the next action.
 *
 * - Returns `{ next }` when more batches are required (caller schedules them).
 * - Returns `{ done: true }` when the full backfill is complete (lock already
 *   released internally).
 * - Throws on unexpected errors (after performing cleanup internally).
 *
 * The function still calls `host.tools.integrations.channelSyncCompleted`
 * directly because that is a data-plane signal, not a scheduling operation.
 */
export async function syncOutlookBatchFn(
  host: OutlookCalendarSyncHost,
  calendarId: string,
  initialSync: boolean,
  batchNumber: number = 1
): Promise<SyncOutlookBatchResult> {
  try {
    // Auth-token presence check up front: getApi() throws if the token
    // was cleared, and as a queued task that throw becomes a retry loop.
    // Skip cleanly instead.
    const api = await tryGetApiFn(
      host,
      calendarId,
      `syncOutlookBatch (batch ${batchNumber})`
    );
    if (!api) {
      await host.clear(`outlook_sync_state_${calendarId}`);
      await host.tools.store.releaseLock(`sync_${calendarId}`);
      return { done: true };
    }

    // Ensure we have the user's identity for RSVP tagging (only on first batch)
    if (batchNumber === 1) {
      await ensureUserIdentityFn(host, calendarId);
    }

    // Load existing sync state
    const savedState = await host.get<SyncState>(
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
    await processOutlookEventsFn(host, result.events, calendarId, initialSync);

    console.log(
      `Synced ${result.events.length} events in batch ${batchNumber} for calendar ${calendarId}`
    );

    // Save sync state
    await host.set(`outlook_sync_state_${calendarId}`, result.state);

    // Queue next batch as separate task if there's more
    if (result.state.more) {
      return { next: { calendarId, initialSync, batchNumber: batchNumber + 1 } };
    }

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
      await host.set(`outlook_sync_state_${calendarId}`, fullState);
      return { next: { calendarId, initialSync, batchNumber: 1 } };
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
      const seenMasterKeys = await host.tools.store.list("seen_master:");
      const seenMasters = new Set(
        seenMasterKeys.map((k) => k.slice("seen_master:".length))
      );
      const pendingKeys = await host.tools.store.list("pending_occ:");
      const flushLinks: NewLinkWithNotes[] = [];
      let droppedOrphans = 0;
      for (const key of pendingKeys) {
        const pending = await host.get<NewScheduleOccurrence>(key);
        if (!pending) {
          await host.clear(key);
          continue;
        }
        const occurrenceDate =
          pending.occurrence instanceof Date
            ? pending.occurrence
            : new Date(pending.occurrence as unknown as string);
        const suffix = `:${occurrenceDate.toISOString()}`;
        if (!key.startsWith("pending_occ:") || !key.endsWith(suffix)) {
          // Malformed key — drop it.
          await host.clear(key);
          continue;
        }
        const canonical = key.slice(
          "pending_occ:".length,
          key.length - suffix.length
        );
        if (!seenMasters.has(canonical)) {
          droppedOrphans += 1;
          await host.clear(key);
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
        await host.clear(key);
      }
      if (flushLinks.length > 0 || droppedOrphans > 0) {
        console.log(
          `[OutlookCalendar] full-pass flush: calendar=${calendarId} ` +
            `flushedLinks=${flushLinks.length} ` +
            `droppedOrphans=${droppedOrphans}`
        );
      }
      if (flushLinks.length > 0) {
        await host.tools.integrations.saveLinks(flushLinks);
      }

      // Clear master markers for the next initial sync.
      for (const key of seenMasterKeys) {
        await host.clear(key);
      }
    }

    // Initial sync is fully complete — clear the "syncing…" indicator
    // on the connection. Gated on initialSync (not phase), so a
    // corrupted state that bypassed the quick→full transition still
    // signals completion instead of leaving the UI stuck on "Syncing".
    if (initialSync) {
      await host.tools.integrations.channelSyncCompleted(calendarId);
    }

    // Release lock when sync completes (no more batches).
    await host.tools.store.releaseLock(`sync_${calendarId}`);
    return { done: true };
  } catch (error) {
    console.error(
      `Outlook Calendar sync failed for ${calendarId} in batch ${batchNumber}:`,
      error
    );

    // Release lock and clear state so future syncs aren't permanently
    // blocked. Even if this release fails, the lock's TTL will expire it.
    await host.tools.store.releaseLock(`sync_${calendarId}`);
    await host.clear(`outlook_sync_state_${calendarId}`);

    // Clear any `pending_occ:` / `seen_master:` markers buffered by
    // this run. Otherwise the next initial sync would inherit them and
    // the full-pass orphan flush could materialise empty Untitled
    // threads from leftover-but-now-stale buffers.
    try {
      await clearBuffersFn(host, calendarId);
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
        await host.tools.integrations.channelSyncCompleted(calendarId);
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

// ---------------------------------------------------------------------------
// Watch (subscription) lifecycle — extracted functions
// ---------------------------------------------------------------------------

/**
 * Computes the renewal schedule for an Outlook subscription.
 *
 * Reads the stored watch data and returns:
 * - `{ immediate: true }` when the renewal window has already passed (the
 *   caller should renew synchronously).
 * - `{ firstRunAt, intervalMs }` when a future renewal should be scheduled
 *   with `scheduleRecurring`.
 *
 * Returns `null` when no watch data is found (nothing to schedule).
 */
export async function scheduleSubscriptionRenewalFn(
  host: OutlookCalendarSyncHost,
  calendarId: string
): Promise<SubscriptionRenewalSchedule | null> {
  const watchData = await host.get<WatchState>(`outlook_watch_${calendarId}`);
  if (!watchData?.expiry) {
    console.warn(`No watch data found for calendar ${calendarId}`);
    return null;
  }

  // Calculate renewal time: RENEWAL_LEAD_MS before expiry
  const expiry =
    watchData.expiry instanceof Date
      ? watchData.expiry
      : new Date(watchData.expiry);
  const renewalTime = new Date(expiry.getTime() - RENEWAL_LEAD_MS);

  // Don't schedule if already past renewal time (edge case)
  if (renewalTime <= new Date()) {
    return { immediate: true };
  }

  return {
    firstRunAt: renewalTime,
    intervalMs: 1.5 * 24 * 60 * 60 * 1000,
  };
}

/**
 * Renew an Outlook subscription by extending its expiry via PATCH.
 *
 * Returns a descriptor the caller acts on:
 * - `{ renewed: true }`: PATCH succeeded; the caller should schedule the next
 *   proactive renewal.
 * - `{ recreate: true }`: PATCH failed; the old subscription was deleted and
 *   the stored watch data cleared, so the caller should re-run
 *   `setupOutlookWatch` (which re-creates the subscription AND re-schedules
 *   the next renewal).
 * - `{ done: true }`: nothing to do (missing watch data or token), or an
 *   unexpected error already logged internally.
 *
 * Gracefully handles errors without throwing.
 */
export async function renewOutlookWatchFn(
  host: OutlookCalendarSyncHost,
  calendarId: string
): Promise<RenewOutlookWatchResult> {
  try {
    const oldWatchData = await host.get<WatchState>(
      `outlook_watch_${calendarId}`
    );
    if (!oldWatchData?.subscriptionId) {
      console.warn(
        `No watch data found for calendar ${calendarId}, skipping renewal`
      );
      return { done: true };
    }

    const api = await tryGetApiFn(host, calendarId, "renewOutlookWatch");
    if (!api) {
      return { done: true };
    }

    // PATCH the subscription to extend the expiry. Keeps the
    // subscription id stable, so we don't have to re-create the watch
    // state or invalidate any client validation that already happened.
    const newExpiry = new Date();
    newExpiry.setDate(newExpiry.getDate() + SUBSCRIPTION_DURATION_DAYS);

    try {
      await api.renewSubscription(oldWatchData.subscriptionId, newExpiry);
      const updatedWatchState: WatchState = {
        ...oldWatchData,
        expiry: newExpiry,
      };
      await host.set(`outlook_watch_${calendarId}`, updatedWatchState);

      // Caller schedules the next renewal 24h before the new expiry.
      return { renewed: true };
    } catch (error) {
      console.warn(
        `PATCH renewal failed for ${calendarId}, falling back to delete+recreate:`,
        error
      );
      // Fallback: delete + recreate. The caller re-runs setupOutlookWatch
      // which reschedules the next renewal task at the end.
      try {
        await api.deleteSubscription(oldWatchData.subscriptionId);
      } catch (delErr) {
        console.warn(
          `Failed to delete old subscription for ${calendarId}:`,
          delErr
        );
      }
      await host.clear(`outlook_watch_${calendarId}`);
      return { recreate: true };
    }
  } catch (error) {
    console.error(
      `Failed to renew Outlook subscription for ${calendarId}:`,
      error
    );
    return { done: true };
  }
}

/**
 * Registers an MS Graph subscription (push-notification watch) for the given
 * calendar using a pre-created webhook URL.
 *
 * Does NOT create the webhook (the caller does that — it requires the
 * connector's own `onOutlookWebhook` callback) and does NOT schedule the
 * renewal (the caller does that after this returns `{ ok: true }`).
 *
 * Returns `{ skipped: true }` when the webhook URL is localhost or when
 * subscription creation fails (errors are logged internally, never thrown);
 * returns `{ ok: true }` when the subscription was created and the watch state
 * persisted.
 */
export async function setupOutlookWatchFn(
  host: OutlookCalendarSyncHost,
  webhookUrl: string,
  calendarId: string
): Promise<SetupOutlookWatchResult> {
  // Auth-token presence check up front: getApi() throws if the token
  // was cleared, and as a queued task that throw becomes a retry loop.
  // Skip cleanly instead.
  const api = await tryGetApiFn(host, calendarId, "setupOutlookWatch");
  if (!api) {
    return { skipped: true };
  }

  // Skip webhook setup for localhost (development mode)
  if (webhookUrl.includes("localhost") || webhookUrl.includes("127.0.0.1")) {
    return { skipped: true };
  }

  // Microsoft Graph subscriptions expire — set expiry to the maximum
  // allowed lifetime for calendar resources.
  const expirationDate = new Date();
  expirationDate.setDate(expirationDate.getDate() + SUBSCRIPTION_DURATION_DAYS);

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

    await host.set(`outlook_watch_${calendarId}`, watchState);

    return { ok: true };
  } catch (error) {
    console.error("Failed to setup Outlook webhook:", error);
    // Continue without webhook - sync will still work via manual triggers
    return { skipped: true };
  }
}

// ---------------------------------------------------------------------------
// Incremental (webhook-driven) sync — extracted functions
// ---------------------------------------------------------------------------

/**
 * Computes whether the stored subscription is within the reactive renewal
 * window (used by the webhook handler to fire a best-effort renewal).
 *
 * Returns `true` when the watch exists and its expiry is closer than
 * RENEWAL_LEAD_MS; `false` otherwise.
 */
export async function watchNeedsReactiveRenewalFn(
  host: OutlookCalendarSyncHost,
  calendarId: string
): Promise<boolean> {
  const watchData = await host.get<WatchState>(`outlook_watch_${calendarId}`);
  if (!watchData?.expiry) {
    return false;
  }
  const expiry =
    watchData.expiry instanceof Date
      ? watchData.expiry
      : new Date(watchData.expiry);
  const msUntilExpiry = expiry.getTime() - Date.now();
  return msUntilExpiry < RENEWAL_LEAD_MS;
}

/**
 * Acquires the sync lock and prepares for a webhook-driven incremental sync.
 * Returns a descriptor the caller uses to schedule the first batch.
 *
 * Does NOT create or enqueue the syncOutlookBatch callback — the caller is
 * responsible for that after this returns `{ next }`.
 *
 * Returns `{ done: true }` when the lock isn't acquired or the token is
 * missing (lock released internally on the latter).
 */
export async function startIncrementalSyncFn(
  host: OutlookCalendarSyncHost,
  calendarId: string
): Promise<StartIncrementalSyncResult> {
  // Acquire sync lock to prevent the webhook-driven incremental sync
  // from racing an in-progress initial sync (both write to
  // outlook_sync_state_<id>).
  const acquired = await host.tools.store.acquireLock(
    `sync_${calendarId}`,
    SYNC_LOCK_TTL_MS
  );
  if (!acquired) {
    return { done: true };
  }

  // Auth-token presence check up front — same retry-loop concern as
  // syncOutlookBatch. Release the lock if we bail.
  const api = await tryGetApiFn(host, calendarId, "startIncrementalSync");
  if (!api) {
    await host.tools.store.releaseLock(`sync_${calendarId}`);
    return { done: true };
  }

  return {
    next: { calendarId, initialSync: false, batchNumber: 1 },
  };
}

// ---------------------------------------------------------------------------
// RSVP write-back — extracted function
// ---------------------------------------------------------------------------

/**
 * Update RSVP status for the authenticated user on an Outlook Calendar event.
 * Looks up the actor's email from the Graph API to find the correct attendee.
 */
export async function updateEventRSVPWithApiFn(
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
