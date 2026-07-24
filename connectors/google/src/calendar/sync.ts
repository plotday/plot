/**
 * Reusable calendar sync functions extracted from GoogleCalendar.
 *
 * These functions implement the initial backfill state machine (quick pass +
 * full pass) without any connector-level scheduling. They accept a
 * CalendarSyncHost instead of `this` so they can be invoked from both the
 * standalone GoogleCalendar connector and the combined Google connector
 * (which wraps `this` in a key-namespaced proxy).
 *
 * Scheduling (this.callback / this.runTask) is intentionally absent here.
 * Each function returns a descriptor that tells the caller what to do next;
 * the caller owns the scheduling.
 */

import GoogleContacts, {
  enrichLinkContactsFromGoogle,
} from "@plotday/google-contacts";
import {
  type Action,
  ActionType,
  type NewContact,
  type NewLinkWithNotes,
  ConferencingProvider,
} from "@plotday/twister";
import type { ScheduleContactStatus } from "@plotday/twister/schedule";
import type { NewScheduleContact, NewScheduleOccurrence } from "@plotday/twister/schedule";
import type { Thread } from "@plotday/twister";
import type { WebhookRequest } from "@plotday/twister/tools/network";

import {
  GoogleApi,
  type GoogleEvent,
  type SyncState,
  containsHtml,
  extractConferencingLinks,
  hashContent,
  syncGoogleCalendar,
  transformGoogleEvent,
} from "./google-api";

// ---------------------------------------------------------------------------
// Host interface
// ---------------------------------------------------------------------------

/**
 * Minimal interface that a sync host must satisfy. Both GoogleCalendar (using
 * `this` directly) and Google (using a key-namespaced proxy) implement this.
 */
export interface CalendarSyncHost {
  /** Persist a value under a connector-scoped key. */
  set(key: string, value: unknown): Promise<void>;
  /** Retrieve a previously persisted value. Returns null if absent. */
  get<T>(key: string): Promise<T | null>;
  /** Delete a persisted value. */
  clear(key: string): Promise<void>;
  /**
   * Optional read into the MAIL namespace's state, used to check for a
   * `cancel-email:<uid>` marker recorded when the mail sync processed a
   * cancellation email for the same event. Absent on hosts that don't wire
   * mail/calendar together (e.g. the standalone GoogleCalendar connector, or
   * fake hosts in tests) — treated as "no cancel email seen".
   */
  readMailState?<T>(key: string): Promise<T | null>;

  tools: {
    integrations: {
      /** Read the OAuth token for a channel. */
      get(
        channelId: string
      ): Promise<{ token: string; scopes: string[] } | null>;
      /** Persist a batch of links (upsert by source). */
      saveLinks(links: NewLinkWithNotes[]): Promise<void>;
      /** Signal that the initial backfill for a channel has finished. */
      channelSyncCompleted(channelId: string): Promise<void>;
    };
    googleContacts: GoogleContacts;
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
// Return types (descriptors — no scheduling inside the functions)
// ---------------------------------------------------------------------------

/**
 * Return type for {@link runSyncBatch}.
 *
 * - `next`: schedule another batch with these parameters.
 * - `done`: no more batches; the caller should release any held resources.
 */
export type SyncBatchResult =
  | { next: { batchNumber: number; mode: "full" | "incremental" } }
  | { done: true };

/**
 * Return type for {@link runCalendarInit}.
 *
 * - `next`: set up the watch (optional) and then schedule the first batch.
 * - `done`: skip — token missing or lock not acquired.
 */
export type CalendarInitResult =
  | {
      next: {
        batchNumber: number;
        mode: "full" | "incremental";
        initialSync: boolean;
        /** The resolved (non-"primary") calendar id to use for subsequent callbacks. */
        resolvedCalendarId: string;
      };
    }
  | { done: true };

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * Lock TTL covering the worst-case full backfill (quick + full pass).
 * The framework releases the lock automatically after this window even
 * if a worker crashes, so no stuck-sync recovery is needed.
 */
export const SYNC_LOCK_TTL_MS = 2 * 60 * 60 * 1000;

// ---------------------------------------------------------------------------
// Pure helpers (no host state)
// ---------------------------------------------------------------------------

/**
 * Build the canonical identifiers for a calendar event. The first element is
 * the connector-native source (preserves existing thread.key dedup across
 * users). Additional elements are cross-vendor aliases that let other
 * connectors (e.g. meeting-notes apps) bundle into this thread by referencing
 * the same canonical identifier.
 */
export function buildEventSources(opts: {
  iCalUID?: string | null;
  eventId?: string | null;
  fallbackId?: string | null;
}): string[] {
  const { iCalUID, eventId, fallbackId } = opts;
  const sources: string[] = [];
  const primaryId = iCalUID ?? eventId ?? fallbackId;
  if (primaryId) sources.push(`google-calendar:${primaryId}`);
  if (iCalUID) sources.push(`icaluid:${iCalUID}`);
  if (eventId) sources.push(`google-event:${eventId}`);
  return sources;
}

/**
 * De-duplicate a note/link contact roster by email (case-insensitive),
 * keeping the first occurrence. The organizer is both surfaced via
 * `event.organizer` (used to seed the roster first, so its `displayName`
 * wins) and, commonly, listed again in `event.attendees` with
 * `organizer: true` — without this, the message-model roster would carry
 * the same person twice.
 */
export function dedupeContactsByEmail(contacts: NewContact[]): NewContact[] {
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

// ---------------------------------------------------------------------------
// Extracted helper functions (mechanical this.X → host.X)
// ---------------------------------------------------------------------------

/**
 * Build a GoogleApi instance authenticated for the given calendar channel.
 * Throws "Authorization no longer available" if the token is absent.
 */
export async function getApiFn(
  host: CalendarSyncHost,
  calendarId: string
): Promise<GoogleApi> {
  const token = await host.tools.integrations.get(calendarId);
  if (!token) {
    throw new Error("Authorization no longer available");
  }
  return new GoogleApi(token.token);
}

/**
 * Returns the user's primary Google email by calling the Calendar API.
 */
export async function getUserEmailFn(
  host: CalendarSyncHost,
  calendarId: string
): Promise<string> {
  const api = await getApiFn(host, calendarId);
  const calendarList = (await api.call(
    "GET",
    "https://www.googleapis.com/calendar/v3/users/me/calendarList/primary"
  )) as { id: string };
  return calendarList.id;
}

/**
 * Ensures the user's email is stored in connector state (fetches once, then
 * returns the cached value). Used for RSVP tagging on batch 1.
 */
export async function ensureUserIdentityFn(
  host: CalendarSyncHost,
  calendarId: string
): Promise<string> {
  const stored = await host.get<string>("user_email");
  if (stored) return stored;
  const email = await getUserEmailFn(host, calendarId);
  await host.set("user_email", email);
  return email;
}

/**
 * Resolves "primary" to the actual calendar id (user's email).
 * Returns the calendarId unchanged if it's already resolved.
 */
export async function resolveCalendarIdFn(
  host: CalendarSyncHost,
  calendarId: string
): Promise<string> {
  if (calendarId !== "primary") return calendarId;
  const api = await getApiFn(host, calendarId);
  const calendar = (await api.call(
    "GET",
    "https://www.googleapis.com/calendar/v3/calendars/primary"
  )) as { id: string };
  return calendar.id;
}

/**
 * Stamp the first time the connector observes some opaque key, reusing that
 * timestamp on every subsequent observation. Prevents re-syncs from bumping
 * notes forward in the activity feed.
 */
export async function firstSeenAtFn(
  host: CalendarSyncHost,
  storeKey: string,
  seed?: Date
): Promise<Date> {
  const existing = await host.get<string>(storeKey);
  if (existing) return new Date(existing);
  const initial = seed ?? new Date();
  await host.set(storeKey, initial.toISOString());
  return initial;
}

/**
 * Start of the history window the initial backfill imports: Jan 1 of two
 * calendar years ago (mirrors the `historyMin` computed when the quick pass
 * transitions to the full pass). Events scheduled before this were never
 * imported, so a cancellation for one can only materialise a phantom thread.
 */
export function calendarHistoryFloor(now: Date = new Date()): Date {
  const floor = new Date(now);
  floor.setFullYear(floor.getFullYear() - 2);
  floor.setMonth(0, 1);
  floor.setHours(0, 0, 0, 0);
  return floor;
}

/**
 * A cancellation can only meaningfully UPDATE an event the connector already
 * imported (archive its schedule, add a "cancelled" note, flag it unread so
 * the user notices). When the event was never imported, `saveLink` instead
 * CREATES a brand-new thread — a phantom unread item for an event the user
 * never saw in Plot.
 *
 * This happens because the initial backfill deliberately skips events that are
 * already cancelled, then Google's incremental sync (syncToken + showDeleted)
 * later surfaces an old cancelled event — e.g. a years-old recurring master
 * that was deleted long ago, leaking in outside the backfill's `timeMin`
 * window. (Observed right after the Google composite-connector cutover, which
 * starts a fresh sync under a new twist.)
 *
 * Returns true when the cancelled event was never imported, by either signal:
 *  - `event.updated` predates when we first synced this calendar — it was
 *    already cancelled at backfill time, so we skipped it. Precise; relies on
 *    the `first_sync_at_<calendarId>` marker written at init.
 *  - the event's scheduled time is older than the import history floor — it
 *    falls outside the window the backfill imports. Stateless fallback for
 *    connector instances initialised before the marker existed.
 *
 * Real cancellations of imported, still-relevant events satisfy neither
 * (recent `updated`, in-window time) and are kept.
 */
export async function cancellationIsForUnimportedEventFn(
  host: CalendarSyncHost,
  calendarId: string,
  event: GoogleEvent,
  eventTime: Date | null
): Promise<boolean> {
  const firstSyncRaw = await host.get<string>(`first_sync_at_${calendarId}`);
  if (firstSyncRaw && event.updated) {
    if (new Date(event.updated) < new Date(firstSyncRaw)) return true;
  }
  if (eventTime && eventTime < calendarHistoryFloor()) return true;
  return false;
}

/**
 * A cancellation is "fully in the past" when the cancelled event has already
 * ended. Surfacing it adds a "cancelled" note and flips the thread unread for a
 * meeting that already happened — noise, especially when the cancellation syncs
 * in long after the fact (an occurrence cancelled weeks after it occurred).
 *
 * Events that have started but not yet finished (ongoing) and future events are
 * kept, so the user still learns an upcoming/in-progress meeting won't happen.
 *
 * The end is taken from the event's explicit `end` when present (a timed
 * `dateTime`, or an all-day `date` which is already the exclusive next-day
 * boundary). Otherwise it's derived from the start — recurring occurrences
 * usually carry only `originalStartTime` — treating a timed start as the end
 * (duration unknown) and an all-day start as running to the end of its day. An
 * event with no time information at all cannot be judged past and is kept.
 */
export function cancellationIsForPastEventFn(
  event: GoogleEvent,
  now: Date = new Date()
): boolean {
  // Explicit end is the most precise signal.
  if (event.end?.dateTime) return new Date(event.end.dateTime) < now;
  if (event.end?.date) return new Date(event.end.date) < now;

  // No explicit end: derive from the start (or the occurrence's original slot).
  const start = event.start ?? event.originalStartTime;
  if (start?.dateTime) return new Date(start.dateTime) < now;
  if (start?.date) {
    const dayEnd = new Date(start.date);
    dayEnd.setUTCDate(dayEnd.getUTCDate() + 1); // all-day end = next-day midnight
    return dayEnd < now;
  }
  return false;
}

/**
 * A cancellation the user performed themselves shouldn't flip their thread
 * unread — deleting your own appointment is not something to be notified about.
 * Google never tells us *who* cancelled an event, but two signals on the user's
 * own copy imply the user did it:
 *
 *  1. The user organizes the event (`organizer.self`). Only the organizer's
 *     deletion cancels an event for everyone, so a cancelled event the user
 *     organizes was cancelled by the user. This also covers personal events —
 *     you are the organizer of your own solo appointments.
 *  2. The user is the only invitee. A single-participant event can only be
 *     cancelled by that participant. We require POSITIVE evidence here — a
 *     populated attendee list containing only the user — because Google
 *     guarantees only `id`/`status`/`updated` on a cancelled event, so an
 *     *absent* attendee list means "unknown", not "solo".
 *
 * A non-self organizer is decisive the other way: someone else controls the
 * event, so its cancellation should still notify the user (their meeting was
 * cancelled by the host). When neither signal is present (sparse payloads, e.g.
 * most cancelled recurring instances) we return false and the cancellation
 * notifies exactly as before — best-effort suppression that never hides a real
 * "someone else cancelled your meeting".
 */
export function cancellationWasSelfInitiatedFn(event: GoogleEvent): boolean {
  // Someone else organizes it → their action; keep notifying the user.
  if (event.organizer && event.organizer.self !== true) return false;
  // The user organizes it → only the organizer can cancel → self-initiated.
  if (event.organizer?.self === true) return true;

  // No organizer signal: conclude self-initiated only from positive evidence
  // that the user is the sole invitee.
  const attendees = event.attendees ?? [];
  if (attendees.length === 0) return false;
  const hasSelf = attendees.some((att) => att.self === true);
  const hasOther = attendees.some(
    (att) => att.self !== true && att.email && !att.resource
  );
  return hasSelf && !hasOther;
}

/**
 * Clear all `pending_occ:` and `seen_master:` markers for one calendar.
 * Used on recovery, stopSync, and sync-error paths.
 */
export async function clearBuffersFn(
  host: CalendarSyncHost,
  calendarId: string
): Promise<void> {
  const pendingKeys = await host.tools.store.list(`pending_occ:${calendarId}:`);
  for (const key of pendingKeys) {
    await host.clear(key);
  }
  const seenMasterKeys = await host.tools.store.list(
    `seen_master:${calendarId}:`
  );
  for (const key of seenMasterKeys) {
    await host.clear(key);
  }
}

/**
 * Transform a recurring event instance (occurrence) into either an
 * occurrence-only NewLinkWithNotes (for the caller's batched saveLinks),
 * or `null` when the occurrence is buffered to `pending_occ:` storage for
 * cross-batch merging during initial sync. Never saves directly.
 */
export async function prepareEventInstanceFn(
  host: CalendarSyncHost,
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

  if (!event.recurringEventId) {
    console.warn(`No recurring event ID for instance: ${event.id}`);
    return null;
  }

  const masterCanonicalUrl = `google-calendar:${event.iCalUID ?? event.recurringEventId}`;
  const instanceData = transformGoogleEvent(event, calendarId);

  if (event.status === "cancelled") {
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
      start,
      end,
      cancelled: true,
    };

    if (initialSync) {
      const pendingKey = `pending_occ:${calendarId}:${masterCanonicalUrl}:${new Date(
        originalStartTime
      ).toISOString()}`;
      await host.set(pendingKey, cancelledOccurrence);
      console.log(
        `[GoogleCalendar] buffered cancelled instance: ` +
          `master=${masterCanonicalUrl} ` +
          `originalStart=${new Date(originalStartTime).toISOString()} ` +
          `(calendar=${calendarId})`
      );
      return null;
    }

    // Incremental sync: drop the cancellation when the occurrence was never
    // imported (e.g. a years-old instance leaking through the syncToken),
    // which would otherwise create a phantom unread thread.
    if (
      await cancellationIsForUnimportedEventFn(
        host,
        calendarId,
        event,
        new Date(originalStartTime)
      )
    ) {
      console.log(
        `[GoogleCalendar] skipping cancelled occurrence for never-imported ` +
          `master=${masterCanonicalUrl} ` +
          `originalStart=${new Date(originalStartTime).toISOString()} ` +
          `(calendar=${calendarId})`
      );
      return null;
    }

    // Drop the cancellation when the occurrence has already ended — a past
    // occurrence's cancellation is just noise (and would flip the thread
    // unread for a meeting that already happened).
    if (cancellationIsForPastEventFn(event)) {
      console.log(
        `[GoogleCalendar] skipping cancelled occurrence fully in the past ` +
          `master=${masterCanonicalUrl} ` +
          `originalStart=${new Date(originalStartTime).toISOString()} ` +
          `(calendar=${calendarId})`
      );
      return null;
    }

    const isAllDay = !event.originalStartTime?.dateTime;
    const formattedDate = new Date(originalStartTime).toLocaleDateString(
      "en-US",
      {
        dateStyle: "long",
        ...(isAllDay ? { timeZone: "UTC" } : {}),
      }
    );
    const occurrenceIso = new Date(originalStartTime).toISOString();
    const cancelFirstSeen = await firstSeenAtFn(
      host,
      `cancel_seen:${masterCanonicalUrl}:${occurrenceIso}`,
      event.updated ? new Date(event.updated) : undefined
    );
    const cancelNote = {
      key: `cancellation-${occurrenceIso}`,
      content: `The ${formattedDate} occurrence was cancelled.`,
      contentType: "text" as const,
      created: cancelFirstSeen,
    };

    return {
      type: "event",
      title: undefined,
      source: masterCanonicalUrl,
      sources: buildEventSources({
        iCalUID: event.iCalUID,
        fallbackId: event.recurringEventId,
      }),
      channelId: calendarId,
      meta: { syncProvider: "google", syncableId: calendarId },
      scheduleOccurrences: [cancelledOccurrence],
      notes: [cancelNote],
      // A cancelled occurrence is only meaningful as an annotation on the
      // recurring master the user already has. When Plot never imported that
      // master (e.g. a newly split series whose confirmed master hasn't synced
      // yet, so only its cancelled future occurrences arrived), creating a
      // thread here would surface a titleless, scheduleless "cancelled" thread
      // for an event the user never saw. `updateOnly` makes the platform apply
      // this only if the master's thread already exists, and skip it otherwise.
      updateOnly: true,
      // Don't flip the thread unread when the user cancelled the occurrence
      // themselves. Cancelled instances are usually sparse (no organizer /
      // attendees), so this rarely fires — best-effort, never over-suppresses.
      ...(cancellationWasSelfInitiatedFn(event) ? { unread: false } : {}),
    };
  }

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

  const instanceSchedule = instanceData.schedules?.[0];
  const occurrenceStart =
    instanceSchedule?.start ?? new Date(originalStartTime);

  const occurrence: NewScheduleOccurrence = {
    occurrence: new Date(originalStartTime),
    start: occurrenceStart,
    contacts,
    ...(initialSync ? { unread: false } : {}),
  };

  if (instanceSchedule?.end !== undefined && instanceSchedule?.end !== null) {
    occurrence.end = instanceSchedule.end;
  }

  if (initialSync) {
    const pendingKey = `pending_occ:${calendarId}:${masterCanonicalUrl}:${new Date(
      originalStartTime
    ).toISOString()}`;
    await host.set(pendingKey, occurrence);
    console.log(
      `[GoogleCalendar] buffered exception instance: ` +
        `master=${masterCanonicalUrl} ` +
        `originalStart=${new Date(originalStartTime).toISOString()} ` +
        `(calendar=${calendarId})`
    );
    return null;
  }

  return {
    type: "event",
    title: undefined,
    source: masterCanonicalUrl,
    sources: buildEventSources({
      iCalUID: event.iCalUID,
      fallbackId: event.recurringEventId,
    }),
    channelId: calendarId,
    meta: { syncProvider: "google", syncableId: calendarId },
    scheduleOccurrences: [occurrence],
    notes: [],
  };
}

/**
 * Process a page of Google Calendar events: transforms them, coalesces by
 * canonical source (so master + exception instances collapse into one
 * NewLinkWithNotes), drains pending_occ buffers for any masters present, and
 * saves the batch via integrations.saveLinks.
 */
export async function processCalendarEventsFn(
  host: CalendarSyncHost,
  events: GoogleEvent[],
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
      existing.accessContacts = link.accessContacts ?? existing.accessContacts;
      existing.author = link.author ?? existing.author;
      existing.created = link.created ?? existing.created;
      existing.meta = { ...(existing.meta || {}), ...(link.meta || {}) };
      if (link.unread !== undefined) existing.unread = link.unread;
      if (link.archived !== undefined) existing.archived = link.archived;
      // Never let the merge LOWER an already-set priority. Recurring-event
      // instance links carry no priority; when an instance is coalesced
      // before its master in the same batch, this floor ensures the
      // master's priority (>= 1) survives regardless of ordering.
      existing.priority = Math.max(existing.priority ?? 0, link.priority ?? 0);
    }
  };

  for (const event of events) {
    try {
      let validAttendees: typeof event.attendees = [];
      let authorContact: NewContact | undefined = undefined;
      if (event.organizer?.email) {
        authorContact = {
          email: event.organizer.email,
          name: event.organizer.displayName,
        };
      }

      if (event.attendees && event.attendees.length > 0) {
        validAttendees = event.attendees.filter(
          (att) => att.email && !att.resource
        );
      }

      if (event.recurringEventId && event.originalStartTime) {
        if (initialSync) {
          const canonical = `google-calendar:${
            event.iCalUID ?? event.recurringEventId
          }`;
          console.log(
            `[GoogleCalendar] instance: master=${canonical} ` +
              `status=${event.status ?? "n/a"} ` +
              `originalStart=${
                event.originalStartTime?.dateTime ??
                event.originalStartTime?.date ??
                "n/a"
              } ` +
              `masterAlreadyInBatch=${linksBySource.has(canonical)} ` +
              `(calendar=${calendarId})`
          );
        }
        const instanceLink = await prepareEventInstanceFn(
          host,
          event,
          calendarId,
          initialSync
        );
        if (instanceLink) addLink(instanceLink as LinkWithSource);
      } else {
        const activityData = transformGoogleEvent(event, calendarId);

        if (event.status === "cancelled") {
          if (initialSync) continue;

          // Drop the cancellation when the event was never imported (e.g. an
          // old cancelled event leaking through the incremental syncToken's
          // showDeleted results). Creating a thread here would surface a
          // phantom unread item for an event the user never saw in Plot.
          const cancelledEventTime = event.start?.dateTime
            ? new Date(event.start.dateTime)
            : event.start?.date
            ? new Date(event.start.date)
            : event.updated
            ? new Date(event.updated)
            : event.created
            ? new Date(event.created)
            : null;
          if (
            await cancellationIsForUnimportedEventFn(
              host,
              calendarId,
              event,
              cancelledEventTime
            )
          ) {
            console.log(
              `[GoogleCalendar] skipping cancellation for never-imported ` +
                `event=${event.iCalUID ?? event.id} (calendar=${calendarId})`
            );
            continue;
          }

          // Drop the cancellation when the event has already ended — a past
          // event's cancellation is just noise (and would flip the thread
          // unread for a meeting that already happened).
          if (cancellationIsForPastEventFn(event)) {
            console.log(
              `[GoogleCalendar] skipping cancellation fully in the past ` +
                `event=${event.iCalUID ?? event.id} (calendar=${calendarId})`
            );
            continue;
          }

          const canonicalUrl = `google-calendar:${event.iCalUID ?? event.id}`;
          const cancelFirstSeen = await firstSeenAtFn(
            host,
            `cancel_seen:${canonicalUrl}`,
            event.updated ? new Date(event.updated) : undefined
          );

          // Roster for the message-model thread: organizer + attendees (mirrors
          // the live-event path's attendeeMentions below), so a cancellation
          // that arrives without ever seeing the event confirmed still has a
          // "Reply all" audience.
          const rawCancelMentions: NewContact[] = [];
          if (authorContact) rawCancelMentions.push(authorContact);
          for (const att of validAttendees) {
            if (att.email) {
              rawCancelMentions.push({ email: att.email, name: att.displayName });
            }
          }
          const cancelMentions = dedupeContactsByEmail(rawCancelMentions);

          // Prefer the cancellation email's own message over our generic note
          // when the mail sync already recorded one for this event (Plan B
          // mail/calendar bundling) — avoids a redundant, lower-fidelity note
          // on the same thread. The structural cancellation (status/schedule/
          // unread below) always applies regardless of this signal.
          const cancelEmailSeen =
            (await host.readMailState?.(
              `cancel-email:${event.iCalUID ?? event.id}`
            )) != null;

          const cancelNote = {
            key: "cancellation" as const,
            content: "This event was cancelled.",
            contentType: "text" as const,
            created: cancelFirstSeen,
            accessContacts: cancelMentions,
          };

          const link: NewLinkWithNotes = {
            channelId: calendarId,
            source: canonicalUrl,
            sources: buildEventSources({
              iCalUID: event.iCalUID,
              eventId: event.id,
            }),
            created: event.created ? new Date(event.created) : undefined,
            type: "event",
            title: activityData.title || undefined,
            status: "Cancelled",
            preview: "Cancelled",
            priority: event.organizer?.self
              ? 100
              : event.attendees?.some((a) => a.self)
              ? 50
              : 1,
            access: "private",
            accessContacts: cancelMentions,
            author: authorContact,
            meta: activityData.meta ?? null,
            notes: cancelEmailSeen ? [] : [cancelNote],
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
            // Record the cancellation (archive the schedule, add the note) but
            // don't flip the thread unread when the user cancelled it themselves.
            ...(initialSync || cancellationWasSelfInitiatedFn(event)
              ? { unread: false }
              : {}),
            ...(initialSync ? { archived: false } : {}),
          };

          link.meta = {
            ...link.meta,
            syncProvider: "google",
            syncableId: calendarId,
            iCalUID: event.iCalUID ?? null,
          };

          addLink(link as LinkWithSource);
          continue;
        }

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

        const actions: Action[] = [];
        const seenUrls = new Set<string>();

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

        if (event.hangoutLink && !seenUrls.has(event.hangoutLink)) {
          seenUrls.add(event.hangoutLink);
          actions.push({
            type: ActionType.conferencing,
            url: event.hangoutLink,
            provider: ConferencingProvider.googleMeet,
          });
        }

        if (event.htmlLink) {
          actions.push({
            type: ActionType.external,
            title: "View in Calendar",
            url: event.htmlLink,
          });
        }

        const descriptionValue =
          activityData.meta?.description || event.description;
        const description =
          typeof descriptionValue === "string" ? descriptionValue : null;
        const hasDescription = description && description.trim().length > 0;
        const hasActions = actions.length > 0;

        if (!activityData.type) {
          continue;
        }

        const canonicalUrl = `google-calendar:${event.iCalUID ?? event.id}`;

        // If a prior sync recorded this event as cancelled (whole-event), it
        // archived the base schedule and left a "This event was cancelled."
        // note. Google now reports the event live again, so we must reverse
        // both: un-archive the schedule(s) below and archive the stale
        // cancellation note. Without this the app keeps treating the series as
        // cancelled (an archived base recurring schedule = whole series
        // cancelled) even though the link's status is Confirmed.
        const wasCancelled =
          (await host.get<string>(`cancel_seen:${canonicalUrl}`)) != null;

        const descHash = hasDescription
          ? await hashContent(description)
          : null;
        const descFirstSeen = descHash
          ? await firstSeenAtFn(
              host,
              `desc_seen:${canonicalUrl}:${descHash}`,
              event.created ? new Date(event.created) : undefined
            )
          : undefined;
        const rawAttendeeMentions: NewContact[] = [];
        if (authorContact) rawAttendeeMentions.push(authorContact);
        for (const att of validAttendees) {
          if (att.email) {
            rawAttendeeMentions.push({
              email: att.email,
              name: att.displayName,
            });
          }
        }
        const attendeeMentions = dedupeContactsByEmail(rawAttendeeMentions);

        const descriptionNote =
          hasDescription && descHash
            ? {
                key: `description-${descHash}`,
                content: description,
                contentType:
                  description && containsHtml(description)
                    ? ("html" as const)
                    : ("text" as const),
                created: descFirstSeen,
                accessContacts: attendeeMentions,
                ...(authorContact ? { author: authorContact } : {}),
              }
            : null;

        const notes = [
          ...(descriptionNote ? [descriptionNote] : []),
          // Archive the "This event was cancelled." note the cancellation pass
          // added under this key. Only emitted when a cancellation was actually
          // recorded, so we never insert a spurious archived note.
          ...(wasCancelled
            ? [
                {
                  key: "cancellation" as const,
                  content: "This event was cancelled.",
                  contentType: "text" as const,
                  archived: true,
                  accessContacts: attendeeMentions,
                },
              ]
            : []),
        ];

        const link: NewLinkWithNotes = {
          channelId: calendarId,
          source: canonicalUrl,
          sources: buildEventSources({
            iCalUID: event.iCalUID,
            eventId: event.id,
          }),
          created: event.created ? new Date(event.created) : undefined,
          type: "event",
          status:
            event.status === "confirmed"
              ? "Confirmed"
              : event.status === "tentative"
              ? "Tentative"
              : undefined,
          title: activityData.title || "",
          priority: event.organizer?.self
            ? 100
            : event.attendees?.some((a) => a.self)
            ? 50
            : 1,
          access: "private",
          accessContacts: attendeeMentions,
          author: authorContact,
          meta: activityData.meta ?? null,
          actions: hasActions ? actions : undefined,
          sourceUrl: event.htmlLink ?? null,
          notes,
          preview: hasDescription ? description : null,
          // Explicitly un-archive the base schedule when reversing a prior
          // cancellation; otherwise leave `archived` unset (incremental syncs
          // don't touch it — see the initial/incremental convention below).
          schedules: wasCancelled
            ? activityData.schedules?.map((s) => ({ ...s, archived: false }))
            : activityData.schedules,
          scheduleOccurrences: activityData.scheduleOccurrences,
          ...(initialSync ? { unread: false } : {}),
          ...(initialSync ? { archived: false } : {}),
        };

        link.meta = {
          ...link.meta,
          syncProvider: "google",
          syncableId: calendarId,
          iCalUID: event.iCalUID ?? null,
        };

        addLink(link as LinkWithSource);

        if (wasCancelled) {
          // Reversal recorded on this link — drop the marker so we don't keep
          // re-archiving the (now already-archived) cancellation note on every
          // subsequent sync of this confirmed event.
          await host.clear(`cancel_seen:${canonicalUrl}`);
        }
      }
    } catch (error) {
      console.error(`Failed to process event ${event.id}:`, error);
    }
  }

  // Drain pending_occ buffers for any masters present in this batch.
  let drainedTotal = 0;
  for (const [source, link] of linksBySource.entries()) {
    const pendingPrefix = `pending_occ:${calendarId}:${source}:`;
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
      `[GoogleCalendar] drain: master=${source} ` +
        `merged=${pendingKeys.length} (calendar=${calendarId})`
    );
  }
  if (initialSync) {
    console.log(
      `[GoogleCalendar] processCalendarEvents end: calendar=${calendarId} ` +
        `events=${events.length} masters=${linksBySource.size} ` +
        `drained=${drainedTotal}`
    );

    for (const source of linksBySource.keys()) {
      await host.set(`seen_master:${calendarId}:${source}`, true);
    }
  }

  const batch = Array.from(linksBySource.values());
  if (batch.length > 0) {
    try {
      const token = await host.tools.integrations.get(calendarId);
      if (token) {
        await enrichLinkContactsFromGoogle(batch, token.token, token.scopes);
      }
    } catch (err) {
      console.warn(
        "Failed to enrich Google Calendar contacts (non-blocking):",
        err
      );
    }

    await host.tools.integrations.saveLinks(batch);
  }
}

// ---------------------------------------------------------------------------
// Main extracted sync functions
// ---------------------------------------------------------------------------

/**
 * Extracted backfill state machine. Processes one batch of calendar events and
 * returns a descriptor for the next action.
 *
 * - Returns `{ next }` when more batches are required (caller schedules them).
 * - Returns `{ done: true }` when the full backfill is complete.
 * - Throws on unexpected errors (after performing cleanup internally).
 *
 * The function still calls `host.tools.integrations.channelSyncCompleted`
 * directly because that is a data-plane signal, not a scheduling operation.
 */
export async function runSyncBatch(
  host: CalendarSyncHost,
  batchNumber: number,
  mode: "full" | "incremental",
  calendarId: string,
  initialSync: boolean
): Promise<SyncBatchResult> {
  try {
    const token = await host.tools.integrations.get(calendarId);
    if (!token) {
      console.warn(
        `Auth token missing for calendar ${calendarId} at batch ${batchNumber}, skipping`
      );
      await host.clear(`sync_state_${calendarId}`);
      await host.tools.store.releaseLock(`sync_${calendarId}`);
      return { done: true };
    }

    if (batchNumber === 1) {
      await ensureUserIdentityFn(host, calendarId);
    }

    const state = await host.get<SyncState>(`sync_state_${calendarId}`);
    if (!state) {
      await host.tools.store.releaseLock(`sync_${calendarId}`);
      return { done: true };
    }

    // Convert date strings back to Date objects after deserialization.
    if (state.min && typeof state.min === "string") {
      state.min = new Date(state.min);
    }
    if (state.max && typeof state.max === "string") {
      state.max = new Date(state.max);
    }

    const api = new GoogleApi(token.token);
    const result = await syncGoogleCalendar(api, calendarId, state);

    if (result.events.length > 0) {
      await processCalendarEventsFn(host, result.events, calendarId, initialSync);
    }

    await host.set(`sync_state_${calendarId}`, result.state);

    if (result.state.more) {
      // More pages in this pass — schedule the next batch.
      return { next: { batchNumber: batchNumber + 1, mode } };
    }

    // Persist sync token for future incremental syncs.
    if (result.state.state) {
      await host.set(`last_sync_token_${calendarId}`, result.state.state);
    }

    // Quick pass done: transition to full pass without releasing the lock.
    if (state.phase === "quick") {
      const historyMin = calendarHistoryFloor();
      const fullState: SyncState = {
        calendarId,
        min: historyMin,
        max: null,
        sequence: 1,
        phase: "full",
      };
      await host.set(`sync_state_${calendarId}`, fullState);
      return { next: { batchNumber: 1, mode } };
    }

    // Full pass (or incremental pass) done.
    if (mode === "full") {
      // Flush leftover pending_occ buffers whose master was seen this pass.
      const seenMasterPrefix = `seen_master:${calendarId}:`;
      const pendingPrefix = `pending_occ:${calendarId}:`;
      const seenMasterKeys = await host.tools.store.list(seenMasterPrefix);
      const seenMasters = new Set(
        seenMasterKeys.map((k) => k.slice(seenMasterPrefix.length))
      );
      const pendingKeys = await host.tools.store.list(pendingPrefix);
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
            : new Date(pending.occurrence);
        const suffix = `:${occurrenceDate.toISOString()}`;
        if (!key.startsWith(pendingPrefix) || !key.endsWith(suffix)) {
          await host.clear(key);
          continue;
        }
        const canonical = key.slice(
          pendingPrefix.length,
          key.length - suffix.length
        );
        if (!seenMasters.has(canonical)) {
          droppedOrphans += 1;
          await host.clear(key);
          continue;
        }
        flushLinks.push({
          type: "event",
          title: undefined,
          source: canonical,
          channelId: calendarId,
          meta: { syncProvider: "google", syncableId: calendarId },
          scheduleOccurrences: [pending],
          notes: [],
        });
        await host.clear(key);
      }
      if (flushLinks.length > 0 || droppedOrphans > 0) {
        console.log(
          `[GoogleCalendar] full-pass flush: calendar=${calendarId} ` +
            `flushedLinks=${flushLinks.length} ` +
            `droppedOrphans=${droppedOrphans}`
        );
      }
      if (flushLinks.length > 0) {
        await host.tools.integrations.saveLinks(flushLinks);
      }

      for (const key of seenMasterKeys) {
        await host.clear(key);
      }

      await host.clear(`sync_state_${calendarId}`);
    }

    if (initialSync) {
      await host.tools.integrations.channelSyncCompleted(calendarId);
    }
    await host.tools.store.releaseLock(`sync_${calendarId}`);
    return { done: true };
  } catch (error) {
    console.error(
      `Error in sync batch ${batchNumber} for calendar ${calendarId}:`,
      error
    );

    await host.tools.store.releaseLock(`sync_${calendarId}`);
    await host.clear(`sync_state_${calendarId}`);

    try {
      await clearBuffersFn(host, calendarId);
    } catch (cleanupError) {
      console.error(
        `Failed to clear pending buffers after sync error for ${calendarId}:`,
        cleanupError
      );
    }

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

    throw error;
  }
}

/**
 * Extracted calendar initialization: resolves the calendar id, acquires the
 * sync lock, and sets the initial SyncState for the quick pass.
 *
 * Does NOT set up the push webhook (watch setup stays on the concrete
 * connector so it can reference its own callback methods).
 *
 * Returns `{ done: true }` when token is missing or lock is not acquired.
 * Otherwise returns `{ next }` with the parameters for the first syncBatch.
 */
export async function runCalendarInit(
  host: CalendarSyncHost,
  calendarId: string
): Promise<CalendarInitResult> {
  const token = await host.tools.integrations.get(calendarId);
  if (!token) {
    console.warn(
      `Auth token missing for calendar ${calendarId} during initCalendar, skipping`
    );
    return { done: true };
  }

  const resolvedCalendarId = await resolveCalendarIdFn(host, calendarId);

  const acquired = await host.tools.store.acquireLock(
    `sync_${resolvedCalendarId}`,
    SYNC_LOCK_TTL_MS
  );
  if (!acquired) {
    return { done: true };
  }

  // Record (once) when we first started syncing this calendar. Used later to
  // drop cancellations of events that were already cancelled before we ever
  // imported anything — those would otherwise create phantom unread threads.
  const firstSyncKey = `first_sync_at_${resolvedCalendarId}`;
  if (!(await host.get<string>(firstSyncKey))) {
    await host.set(firstSyncKey, new Date().toISOString());
  }

  const initialState: SyncState = {
    calendarId: resolvedCalendarId,
    min: new Date(),
    max: null,
    sequence: 1,
    phase: "quick",
  };

  await host.set(`sync_state_${resolvedCalendarId}`, initialState);

  return {
    next: {
      batchNumber: 1,
      mode: "full",
      initialSync: true,
      resolvedCalendarId,
    },
  };
}

// ---------------------------------------------------------------------------
// Live-update (watch/webhook) + RSVP extracted functions
// ---------------------------------------------------------------------------

/**
 * Return type for {@link setupCalendarWatchFn}.
 *
 * - `skipped`: webhook URL is localhost — watch was not registered.
 * - `ok`: watch registered successfully; caller should schedule renewal at `expiry`.
 */
export type SetupCalendarWatchResult =
  | { skipped: true }
  | { ok: true; expiry: Date };

/**
 * Registers a Google Calendar watch (push-notification subscription) for the
 * given calendar using a pre-created webhook URL.
 *
 * Idempotent: stops any existing watch for this calendar before creating a new
 * one (so a re-dispatch or re-init doesn't orphan the previous subscription).
 *
 * Does NOT schedule watch renewal — the caller is responsible for that after
 * this function returns `{ ok: true, expiry }`.
 *
 * @param host      CalendarSyncHost (for state get/set and integrations access).
 * @param webhookUrl Already-created webhook URL (returned by network.createWebhook).
 * @param calendarId The resolved (non-"primary") calendar id.
 */
export async function setupCalendarWatchFn(
  host: CalendarSyncHost,
  webhookUrl: string,
  calendarId: string
): Promise<SetupCalendarWatchResult> {
  // Idempotent: stop any watch already registered for this calendar.
  try {
    await stopCalendarWatchFn(host, calendarId);
  } catch (error) {
    console.warn(`Failed to stop old watch for ${calendarId}:`, error);
  }

  // Skip watch registration when running locally (no public HTTPS endpoint).
  if (URL.parse(webhookUrl)?.hostname === "localhost") {
    return { skipped: true };
  }

  const api = await getApiFn(host, calendarId);

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

  const expiry = new Date(parseInt(watchData.expiration));
  await host.set(`calendar_watch_${calendarId}`, {
    watchId,
    resourceId: watchData.resourceId,
    secret,
    calendarId,
    expiry,
  });

  return { ok: true, expiry };
}

/**
 * Stop a Google Calendar watch by calling the Google Calendar API (channels/stop).
 * No-op if no watch data is stored for this calendar.
 *
 * @param host       CalendarSyncHost for state get and API access.
 * @param calendarId The resolved calendar id.
 * @param api        Optional pre-created GoogleApi instance (avoids a redundant fetch).
 */
export async function stopCalendarWatchFn(
  host: CalendarSyncHost,
  calendarId: string,
  api?: GoogleApi
): Promise<void> {
  const watchData = await host.get<Record<string, unknown>>(`calendar_watch_${calendarId}`);
  if (!watchData) return;

  const resolvedApi = api ?? (await getApiFn(host, calendarId));

  // https://developers.google.com/calendar/api/v3/reference/channels/stop
  await resolvedApi.call(
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
 * Return type for {@link getWatchRenewalScheduleFn}.
 *
 * - `immediate`: the renewal window has already passed; the caller should
 *   renew the watch immediately instead of scheduling.
 * - `scheduled`: the caller should schedule a recurring renewal with the
 *   given `firstRunAt` and `intervalMs`.
 */
export type WatchRenewalSchedule =
  | { immediate: true }
  | { firstRunAt: Date; intervalMs: number };

/**
 * Computes the renewal schedule for a calendar watch.
 *
 * Reads the stored watch data and returns:
 * - `{ immediate: true }` when the 24-hour pre-expiry window has already
 *   passed (the caller should renew synchronously).
 * - `{ firstRunAt, intervalMs }` when a future renewal should be scheduled
 *   with `scheduleRecurring`.
 *
 * Returns `null` when no watch data is found (nothing to schedule).
 *
 * @param host       CalendarSyncHost for state get.
 * @param calendarId The resolved calendar id.
 */
export async function getWatchRenewalScheduleFn(
  host: CalendarSyncHost,
  calendarId: string
): Promise<WatchRenewalSchedule | null> {
  const watchData = await host.get<Record<string, unknown>>(`calendar_watch_${calendarId}`);
  if (!watchData?.expiry) {
    console.warn(`No watch data found for calendar ${calendarId}`);
    return null;
  }

  const expiry = new Date(watchData.expiry as string);
  const renewalTime = new Date(expiry.getTime() - 24 * 60 * 60 * 1000);

  if (renewalTime <= new Date()) {
    return { immediate: true };
  }

  // Ceiling: half the ~7-day watch lifetime guarantees renewal fires even if
  // a single beat is missed; firstRunAt keeps the precise expiry-24h timing.
  return {
    firstRunAt: renewalTime,
    intervalMs: 3.5 * 24 * 60 * 60 * 1000,
  };
}

/**
 * Return type for {@link validateCalendarWebhookFn}.
 *
 * - `invalid`: the request should be silently ignored (missing headers,
 *   unknown watch id, or invalid secret).
 * - `valid`: the request is authentic; `needsRenewal` indicates the watch
 *   is within 24h of expiry and should be proactively renewed.
 */
export type CalendarWebhookValidation =
  | { invalid: true }
  | { valid: true; needsRenewal: boolean };

/**
 * Validates an incoming Google Calendar webhook push notification.
 *
 * Checks that the required `x-goog-channel-id` and `x-goog-channel-token`
 * headers are present, that the channel id matches the stored watch, and that
 * the secret in the token matches. Returns a validation result the caller acts
 * on (see {@link CalendarWebhookValidation}).
 *
 * @param host       CalendarSyncHost for watch data get.
 * @param request    Incoming webhook request object.
 * @param calendarId The resolved calendar id (encoded in the webhook URL by the caller).
 */
export async function validateCalendarWebhookFn(
  host: CalendarSyncHost,
  request: WebhookRequest,
  calendarId: string
): Promise<CalendarWebhookValidation> {
  const channelId = request.headers["x-goog-channel-id"];
  const channelToken = request.headers["x-goog-channel-token"];

  if (!channelId || !channelToken) {
    console.warn("Google Calendar webhook missing required headers", { calendarId });
    return { invalid: true };
  }

  const watchData = await host.get<Record<string, unknown>>(`calendar_watch_${calendarId}`);

  if (!watchData || watchData.watchId !== channelId) {
    console.warn("Unknown or expired webhook notification");
    return { invalid: true };
  }

  const params = new URLSearchParams(channelToken);
  const secret = params.get("secret");

  if (watchData.secret !== secret) {
    console.warn("Invalid webhook secret");
    return { invalid: true };
  }

  // Reactive expiry check: flag for proactive renewal when close to expiry.
  const expiration = new Date(watchData.expiry as string);
  const hoursUntilExpiry =
    (expiration.getTime() - new Date().getTime()) / (1000 * 60 * 60);

  return { valid: true, needsRenewal: hoursUntilExpiry < 24 };
}

/**
 * Return type for {@link startIncrementalSyncFn}.
 *
 * - `done`: lock not acquired or watch data missing; no batch to schedule.
 * - `next`: batch should be scheduled with mode "incremental".
 */
export type StartIncrementalSyncResult =
  | { done: true }
  | { next: true };

/**
 * Acquires the sync lock and prepares the incremental SyncState for the given
 * calendar. Returns a descriptor the caller uses to schedule the first batch.
 *
 * Does NOT create or enqueue the syncBatch callback — the caller is
 * responsible for that after this function returns `{ next: true }`.
 *
 * @param host       CalendarSyncHost for state get/set and lock management.
 * @param calendarId The resolved calendar id.
 */
export async function startIncrementalSyncFn(
  host: CalendarSyncHost,
  calendarId: string
): Promise<StartIncrementalSyncResult> {
  const acquired = await host.tools.store.acquireLock(
    `sync_${calendarId}`,
    SYNC_LOCK_TTL_MS
  );
  if (!acquired) {
    return { done: true };
  }

  const watchData = await host.get<Record<string, unknown>>(`calendar_watch_${calendarId}`);
  if (!watchData) {
    console.error("No calendar watch data found");
    await host.tools.store.releaseLock(`sync_${calendarId}`);
    return { done: true };
  }

  const syncToken = await host.get<string>(`last_sync_token_${calendarId}`);

  const incrementalState: SyncState = syncToken
    ? {
        calendarId: watchData.calendarId as string,
        state: syncToken,
      }
    : {
        calendarId: watchData.calendarId as string,
        min: new Date(Date.now() - 7 * 24 * 60 * 60 * 1000),
        sequence: 1,
      };

  await host.set(`sync_state_${calendarId}`, incrementalState);
  return { next: true };
}

/**
 * Update the RSVP (attendee response status) for the authenticated user on a
 * Google Calendar event via the Calendar API.
 *
 * Fetches the current event to find the actor's attendee entry (matching by
 * `self === true` or by email from the primary calendarList), then patches the
 * attendees array with the new status.
 *
 * No-op if the actor is not an attendee, or if their status already matches.
 *
 * @param api        Authenticated GoogleApi instance.
 * @param calendarId The calendar id (used for the events API path).
 * @param eventId    The per-calendar event id (from `meta.id`).
 * @param status     The new Google-side RSVP status.
 */
export async function updateEventRSVPWithApiFn(
  api: GoogleApi,
  calendarId: string,
  eventId: string,
  status: "accepted" | "declined" | "needsAction" | "tentative"
): Promise<void> {
  // Fetch the current event to get the attendees list.
  const event = (await api.call(
    "GET",
    `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events/${eventId}`
  )) as GoogleEvent | null;

  if (!event) {
    throw new Error(`Event ${eventId} not found`);
  }

  // Resolve the actor's email from their primary calendar.
  const calendarList = (await api.call(
    "GET",
    "https://www.googleapis.com/calendar/v3/users/me/calendarList/primary"
  )) as { id: string };
  const actorEmail = calendarList.id;

  // Find and update the actor's attendee status.
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

  // No-op if status already matches (prevents infinite loop).
  if (attendees[actorAttendeeIndex].responseStatus === status) {
    return;
  }

  attendees[actorAttendeeIndex].responseStatus = status;

  await api.call(
    "PATCH",
    `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events/${eventId}`,
    undefined,
    { attendees }
  );
}

/**
 * Cancels a Google Calendar event by deleting it. Works uniformly for a
 * standalone/master event and a single occurrence of a recurring series —
 * both are addressed by their own `eventId`, and Google reports a deleted
 * occurrence as a cancelled exception on the next sync rather than removing
 * the series. `GoogleApi.call` treats 410 (already gone) as a no-op.
 */
export async function cancelEventWithApiFn(
  api: GoogleApi,
  calendarId: string,
  eventId: string
): Promise<void> {
  await api.call(
    "DELETE",
    `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events/${eventId}`
  );
}

/**
 * Parameters extracted from a thread for an RSVP write-back.
 *
 * `null` when the thread lacks the required calendar metadata.
 */
export type RSVPParams = {
  calendarId: string;
  eventId: string;
  googleStatus: "accepted" | "declined" | "needsAction";
} | null;

/**
 * Extracts the calendar id, event id, and mapped Google RSVP status from a
 * Plot thread's metadata. Returns `null` when the required fields are absent
 * (no-op case).
 *
 * This is a pure helper — no async operations or side effects.
 *
 * @param thread  The Plot thread for the RSVP'd event.
 * @param status  The Plot-side RSVP status set by the user.
 */
export function extractRSVPParamsFn(
  thread: Thread,
  status: ScheduleContactStatus | null
): RSVPParams {
  const meta = thread.meta as Record<string, unknown> | null;
  // meta.syncableId is the calendar id (set by transformGoogleEvent).
  const calendarId = meta?.syncableId as string | null;
  // meta.id is the per-calendar event id (set by transformGoogleEvent).
  // We use meta.id (not source) because source uses iCalUID for cross-user dedup.
  const eventId = meta?.id as string | null;

  if (!eventId || !calendarId) return null;

  const googleStatus =
    status === "attend"
      ? ("accepted" as const)
      : status === "skip"
      ? ("declined" as const)
      : ("needsAction" as const);

  return { calendarId, eventId, googleStatus };
}
