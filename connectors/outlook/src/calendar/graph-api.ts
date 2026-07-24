import type { ThreadMeta } from "@plotday/twister";
import type { NewSchedule, NewScheduleOccurrence } from "@plotday/twister/schedule";
type Calendar = {
  id: string;
  name: string;
  description: string | null;
  primary: boolean;
};

/**
 * Intermediate type returned by transformOutlookEvent.
 * Contains the data extracted from an Outlook event that will be
 * assembled into a NewLinkWithNotes by the caller.
 */
export type TransformedOutlookEvent = {
  title: string;
  meta: ThreadMeta;
  created?: Date;
  schedules?: Array<Omit<NewSchedule, "threadId">>;
  scheduleOccurrences?: NewScheduleOccurrence[];
};

/**
 * Microsoft Graph API event type
 * https://learn.microsoft.com/en-us/graph/api/resources/event
 */
export type OutlookEvent = {
  id: string;
  iCalUId?: string;
  subject?: string;
  bodyPreview?: string;
  body?: {
    contentType: "text" | "html";
    content?: string;
  };
  start: {
    dateTime: string;
    timeZone: string;
  };
  end: {
    dateTime: string;
    timeZone: string;
  };
  isAllDay?: boolean;
  isCancelled?: boolean;
  type?: "singleInstance" | "occurrence" | "exception" | "seriesMaster";
  seriesMasterId?: string;
  recurrence?: {
    pattern: {
      type:
        | "daily"
        | "weekly"
        | "absoluteMonthly"
        | "relativeMonthly"
        | "absoluteYearly"
        | "relativeYearly";
      interval: number;
      month?: number;
      dayOfMonth?: number;
      daysOfWeek?: string[];
      firstDayOfWeek?: string;
      index?: "first" | "second" | "third" | "fourth" | "last";
    };
    range: {
      type: "endDate" | "noEnd" | "numbered";
      startDate: string;
      endDate?: string;
      recurrenceTimeZone?: string;
      numberOfOccurrences?: number;
    };
  };
  originalStart?: string;
  originalStartTimeZone?: string;
  location?: {
    displayName?: string;
    locationType?: string;
    uniqueId?: string;
    uniqueIdType?: string;
  };
  locations?: Array<{
    displayName?: string;
    locationType?: string;
  }>;
  organizer?: {
    emailAddress?: {
      name?: string;
      address?: string;
    };
  };
  attendees?: Array<{
    type?: "required" | "optional" | "resource";
    status?: {
      response?:
        | "none"
        | "organizer"
        | "tentativelyAccepted"
        | "accepted"
        | "declined"
        | "notResponded";
      time?: string;
    };
    emailAddress?: {
      name?: string;
      address?: string;
    };
  }>;
  webLink?: string;
  onlineMeeting?: {
    joinUrl?: string;
  };
  createdDateTime?: string;
  lastModifiedDateTime?: string;
  "@removed"?: {
    reason: "deleted" | "changed";
  };
};

export type SyncState = {
  calendarId: string;
  state?: string; // nextLink (listing mode) or deltaToken/deltaLink (delta mode)
  more?: boolean;
  min?: Date;
  max?: Date;
  sequence?: number;
  /**
   * Two-pass initial sync phase. `"quick"` walks `timeMin = now` to
   * front-load upcoming meetings; `"full"` walks the full event history
   * afterwards to establish a real delta cursor (see `mode`). Both phases
   * share one sync lock; the quick→full transition swaps state without
   * releasing. Absent for incremental syncs.
   */
  phase?: "quick" | "full";
  /**
   * Which Graph resource `state` continues. Microsoft's `/events/delta`
   * resource ("SyncEvents") rejects `$filter`/`$orderby`/`$select`/`$expand`/
   * `$search` entirely — so any request bounded by `min`/`max` must use a
   * plain, non-delta `/events` listing (`"listing"`) instead of the real
   * delta chain (`"delta"`), which only an unfiltered request may use.
   */
  mode?: "listing" | "delta";
};

/**
 * Microsoft Graph API client for calendar operations
 */
export class GraphApi {
  constructor(public accessToken: string) {}

  /**
   * Make a request to Microsoft Graph API. Retries once on 429/503, honoring
   * a `Retry-After` header (seconds), capped at 15s — matches the retry
   * behavior already in GraphMailApi.call (mail/graph-mail-api.ts). Without
   * this, a transient rate limit during composeChannels (mail + calendar
   * fetching channels concurrently at connect time) surfaces as a hard
   * connect-time failure instead of a brief, self-healing delay.
   */
  public async call(
    method: string,
    url: string,
    params?: { [key: string]: any },
    body?: { [key: string]: any }
  ) {
    const query = params ? `?${new URLSearchParams(params)}` : "";
    const headers = {
      Authorization: `Bearer ${this.accessToken}`,
      Accept: "application/json",
      Prefer: 'outlook.timezone="UTC"', // Always use UTC for consistency
      ...(body ? { "Content-Type": "application/json" } : {}),
    };

    for (let attempt = 0; ; attempt++) {
      const response = await fetch(url + query, {
        method,
        headers,
        ...(body ? { body: JSON.stringify(body) } : {}),
      });

      if (
        (response.status === 429 || response.status === 503) &&
        attempt === 0
      ) {
        const retryAfter = Number(response.headers.get("Retry-After") ?? "2");
        await new Promise((r) =>
          setTimeout(r, Math.min(isNaN(retryAfter) ? 2 : retryAfter, 15) * 1000)
        );
        continue;
      }

      switch (response.status) {
        case 400:
          const responseBody = await response.json();
          throw new Error("Invalid request", { cause: responseBody });
        case 401:
          throw new Error("Authentication failed - token may be expired");
        case 403:
          throw new Error("Access denied - insufficient permissions");
        case 404:
          return null;
        case 410:
          // Gone - delta token expired, need full sync
          return null;
        case 429:
          throw new Error("Rate limit exceeded - too many requests");
        case 200:
        case 201:
        case 204:
          if (response.status === 204) return {}; // No content
          return await response.json();
        case 500:
        case 502:
        case 503:
        case 504:
          throw new Error(`Server error: ${response.status}`);
        default:
          throw new Error(await response.text());
      }
    }
  }

  /**
   * Get list of user's calendars
   */
  async getCalendars(): Promise<Calendar[]> {
    const data = (await this.call(
      "GET",
      "https://graph.microsoft.com/v1.0/me/calendars"
    )) as {
      value: Array<{
        id: string;
        name: string;
        color?: string;
        isDefaultCalendar?: boolean;
        canEdit?: boolean;
      }>;
    } | null;

    if (!data?.value) {
      return [];
    }

    return data.value.map((cal) => ({
      id: cal.id,
      name: cal.name,
      description: cal.color || null,
      primary: cal.isDefaultCalendar || false,
    }));
  }

  /**
   * Create a webhook subscription for calendar changes
   */
  async createSubscription(
    calendarId: string,
    webhookUrl: string,
    expirationDateTime: Date
  ): Promise<{
    id: string;
    expirationDateTime: string;
  }> {
    const resource =
      calendarId === "primary"
        ? "/me/events"
        : `/me/calendars/${calendarId}/events`;

    const body = {
      changeType: "created,updated,deleted",
      notificationUrl: webhookUrl,
      resource: resource,
      expirationDateTime: expirationDateTime.toISOString(),
      clientState: crypto.randomUUID(), // Random secret for verification
    };

    const data = (await this.call(
      "POST",
      "https://graph.microsoft.com/v1.0/subscriptions",
      undefined,
      body
    )) as {
      id: string;
      expirationDateTime: string;
      clientState: string;
    };

    return {
      id: data.id,
      expirationDateTime: data.expirationDateTime,
    };
  }

  /**
   * Delete a webhook subscription
   */
  async deleteSubscription(subscriptionId: string): Promise<void> {
    await this.call(
      "DELETE",
      `https://graph.microsoft.com/v1.0/subscriptions/${subscriptionId}`
    );
  }

  /**
   * Renew a webhook subscription
   */
  async renewSubscription(
    subscriptionId: string,
    expirationDateTime: Date
  ): Promise<void> {
    await this.call(
      "PATCH",
      `https://graph.microsoft.com/v1.0/subscriptions/${subscriptionId}`,
      undefined,
      { expirationDateTime: expirationDateTime.toISOString() }
    );
  }
}

/**
 * Convert Microsoft Graph date object to Date
 */
export function fromMsDate(dateValue?: {
  dateTime: string;
  timeZone: string;
}): Date | undefined {
  if (!dateValue?.dateTime) return undefined;

  // Microsoft Graph returns dates in the format "2021-01-01T00:00:00.0000000"
  // We need to convert to ISO format
  let dateStr = dateValue.dateTime;

  // If timezone is specified and not UTC, we handle it
  if (dateValue.timeZone && dateValue.timeZone !== "UTC") {
    // For simplicity, we're assuming UTC in the API call (via Prefer header)
    // If timezone handling is needed, implement proper conversion here
    console.warn(
      `Non-UTC timezone ${dateValue.timeZone} may need special handling`
    );
  }

  // Ensure the date string ends with Z for UTC
  if (!dateStr.endsWith("Z")) {
    dateStr = dateStr + "Z";
  }

  return new Date(dateStr);
}

/**
 * Convert Microsoft Graph date string to date-only string (YYYY-MM-DD)
 */
export function toDateString(dateValue?: {
  dateTime: string;
  timeZone: string;
}): string | undefined {
  if (!dateValue?.dateTime) return undefined;

  // Extract just the date part (YYYY-MM-DD)
  return dateValue.dateTime.split("T")[0];
}

/**
 * Parse RRULE from Microsoft Graph recurrence pattern
 */
export function parseOutlookRRule(
  recurrence: OutlookEvent["recurrence"]
): string | undefined {
  if (!recurrence) return undefined;

  const pattern = recurrence.pattern;
  const range = recurrence.range;

  let freq = "";
  switch (pattern?.type) {
    case "daily":
      freq = "DAILY";
      break;
    case "weekly":
      freq = "WEEKLY";
      break;
    case "absoluteMonthly":
    case "relativeMonthly":
      freq = "MONTHLY";
      break;
    case "absoluteYearly":
    case "relativeYearly":
      freq = "YEARLY";
      break;
    default:
      return undefined;
  }

  let rrule = `FREQ=${freq}`;

  // Add interval
  if (pattern?.interval && pattern.interval > 1) {
    rrule += `;INTERVAL=${pattern.interval}`;
  }

  // Add BYDAY for weekly recurrence
  if (pattern?.daysOfWeek?.length) {
    const days = pattern.daysOfWeek
      .map((d: string) => d.toUpperCase().substring(0, 2))
      .join(",");
    rrule += `;BYDAY=${days}`;
  }

  // Add BYMONTHDAY for absolute monthly
  if (pattern?.type === "absoluteMonthly" && pattern.dayOfMonth) {
    rrule += `;BYMONTHDAY=${pattern.dayOfMonth}`;
  }

  // Add BYSETPOS for relative monthly (e.g., first Monday)
  if (pattern?.type === "relativeMonthly" && pattern.index) {
    const indexMap = {
      first: 1,
      second: 2,
      third: 3,
      fourth: 4,
      last: -1,
    };
    const pos = indexMap[pattern.index];
    if (pos) {
      rrule += `;BYSETPOS=${pos}`;
    }
  }

  // Add BYMONTH for yearly recurrence
  if (
    (pattern?.type === "absoluteYearly" ||
      pattern?.type === "relativeYearly") &&
    pattern.month
  ) {
    rrule += `;BYMONTH=${pattern.month}`;
  }

  // Add UNTIL or COUNT from range
  if (range?.type === "endDate" && range.endDate) {
    // Convert date to RRULE format (YYYYMMDD or YYYYMMDDTHHmmssZ)
    const endDate = range.endDate
      .replace(/[-:]/g, "")
      .replace(/\.\d{3}Z?$/, "Z");
    rrule += `;UNTIL=${endDate}`;
  } else if (range?.type === "numbered" && range.numberOfOccurrences) {
    rrule += `;COUNT=${range.numberOfOccurrences}`;
  }

  return rrule;
}

/**
 * Parse exception dates (EXDATE) from Outlook events
 * Note: Microsoft Graph doesn't provide EXDATE directly in the recurrence object.
 * Exception dates are represented as separate exception events with type="exception".
 * This function exists for API compatibility but returns empty array.
 */
export function parseOutlookExDates(
  _recurrence?: OutlookEvent["recurrence"]
): Date[] {
  // Microsoft Graph represents exceptions as separate events, not as EXDATE
  // Exception events have type="exception" and seriesMasterId pointing to the master event
  return [];
}

/**
 * Parse additional recurrence dates (RDATE) from Outlook events
 * Note: Microsoft Graph doesn't support RDATE in the recurrence pattern.
 * This function exists for API compatibility but returns empty array.
 */
export function parseOutlookRDates(
  _recurrence?: OutlookEvent["recurrence"]
): Date[] {
  // Microsoft Graph doesn't support RDATE in recurrence patterns
  return [];
}

/**
 * Parse recurrence end date/time from Microsoft Graph recurrence
 */
export function parseOutlookRecurrenceEnd(
  recurrence?: OutlookEvent["recurrence"]
): Date | string | null {
  if (!recurrence?.range) return null;

  const range = recurrence.range;

  if (range.type === "endDate" && range.endDate) {
    // Check if this is a date-only or datetime value
    if (range.endDate.includes("T")) {
      // DateTime value - return as Date
      return new Date(range.endDate);
    } else {
      // Date-only value - return as string
      return range.endDate;
    }
  }

  return null;
}

/**
 * Parse recurrence count from Microsoft Graph recurrence
 */
export function parseOutlookRecurrenceCount(
  recurrence?: OutlookEvent["recurrence"]
): number | null {
  if (!recurrence?.range) return null;

  const range = recurrence.range;

  if (range.type === "numbered" && range.numberOfOccurrences) {
    const count = parseInt(range.numberOfOccurrences.toString());
    return isNaN(count) ? null : count;
  }

  return null;
}

/**
 * Transform Microsoft Graph event into an intermediate representation.
 * The caller assembles this into a NewLinkWithNotes.
 */
export function transformOutlookEvent(
  event: OutlookEvent,
  calendarId: string
): TransformedOutlookEvent | null {
  // Skip deleted events
  if (event["@removed"]) {
    return null;
  }

  // Determine if this is an all-day event
  const isAllDay = event.isAllDay === true;

  // For all-day events, use date strings; for timed events, use Date objects
  const start = isAllDay
    ? toDateString(event.start) || null
    : fromMsDate(event.start) || null;

  const end = isAllDay
    ? toDateString(event.end) || null
    : fromMsDate(event.end) || null;

  // Handle cancelled events differently
  const isCancelled = event.isCancelled === true;

  const result: TransformedOutlookEvent = {
    title: isCancelled
      ? event.subject
        ? `Cancelled: ${event.subject}`
        : "Cancelled Event"
      : event.subject || "",
    meta: {
      eventId: event.id,
      calendarId: calendarId,
      onlineMeetingUrl: event.onlineMeeting?.joinUrl || null,
      iCalUId: event.iCalUId || null,
      isCancelled: event.isCancelled || false,
      originalStart: start instanceof Date ? start.toISOString() : start,
      originalEnd: end instanceof Date ? end.toISOString() : end,
      location: event.location?.displayName || null,
    },
    created: event.createdDateTime
      ? new Date(event.createdDateTime)
      : undefined,
  };

  // Build the primary schedule from start/end
  if (!isCancelled && start) {
    const schedule: Omit<NewSchedule, "threadId"> = {
      start,
      end: end ?? null,
    };

    // Handle recurrence for master events (not instances or exceptions)
    if (event.recurrence && event.type === "seriesMaster") {
      schedule.recurrenceRule = parseOutlookRRule(event.recurrence) ?? null;

      // Parse recurrence count (takes precedence over UNTIL)
      const recurrenceCount = parseOutlookRecurrenceCount(event.recurrence);
      if (recurrenceCount) {
        schedule.recurrenceCount = recurrenceCount;
      } else {
        // Parse recurrence end date if no count
        const recurrenceUntil = parseOutlookRecurrenceEnd(event.recurrence);
        if (recurrenceUntil) {
          schedule.recurrenceUntil = recurrenceUntil;
        }
      }

      // Parse exception dates (currently not available from Graph API directly)
      const exdates = parseOutlookExDates(event.recurrence);
      if (exdates.length > 0) {
        schedule.recurrenceExdates = exdates;
      }
    }

    result.schedules = [schedule];

    // Parse RDATEs (additional occurrence dates not in the recurrence rule)
    // Note: Microsoft Graph API doesn't support RDATE, so this will always be empty
    if (event.recurrence && event.type === "seriesMaster") {
      const rdates = parseOutlookRDates(event.recurrence);
      if (rdates.length > 0) {
        result.scheduleOccurrences = rdates.map((rdate) => ({
          occurrence: rdate,
          start: rdate,
        }));
      }
    }
  }

  // Handle exception events (modifications to recurring event instances)
  // TODO: This should be updated to use the occurrences[] array pattern instead
  // For now, we store the exception info in metadata for future processing
  if (
    event.type === "exception" &&
    event.seriesMasterId &&
    event.originalStart
  ) {
    result.meta.seriesMasterId = event.seriesMasterId;
    result.meta.originalStartDate = new Date(
      event.originalStart
    ).toISOString();
  }

  return result;
}

/**
 * Sync calendar events using Microsoft Graph.
 *
 * Microsoft's `/events/delta` resource ("SyncEvents") rejects
 * `$filter`/`$orderby`/`$select`/`$expand`/`$search` outright — there is no
 * way to bound a delta query by date. So any request with `min`/`max` set
 * (the quick pass, or a manual start with an explicit window) uses a plain,
 * non-delta `/events` listing instead; only a fully unfiltered request may
 * use the real delta chain that yields a `deltaLink` for future incremental
 * syncs.
 */
export async function syncOutlookCalendar(
  api: GraphApi,
  calendarId: string,
  state: SyncState
): Promise<{
  events: OutlookEvent[];
  state: SyncState;
}> {
  const resource =
    calendarId === "primary"
      ? "/me/events"
      : `/me/calendars/${calendarId}/events`;

  const bounded = !!(state.min || state.max);
  const mode: "listing" | "delta" = bounded ? "listing" : "delta";

  let url: string;
  if (state.state && state.state.startsWith("http")) {
    // Continuing pagination via a full nextLink/deltaLink URL.
    url = state.state;
  } else if (state.state) {
    // Continuing a delta chain via a bare deltaToken.
    url = `https://graph.microsoft.com/v1.0${resource}/delta?$deltatoken=${state.state}`;
  } else if (bounded) {
    // Bounded request: plain (non-delta) filtered listing.
    const params: string[] = [];
    if (state.min && state.max) {
      params.push(
        `$filter=start/dateTime ge '${state.min.toISOString()}' and start/dateTime lt '${state.max.toISOString()}'`
      );
    } else if (state.min) {
      params.push(`$filter=start/dateTime ge '${state.min.toISOString()}'`);
    } else if (state.max) {
      params.push(`$filter=start/dateTime lt '${state.max.toISOString()}'`);
    }
    url = `https://graph.microsoft.com/v1.0${resource}?${params.join("&")}`;
  } else {
    // Unbounded: real delta query, no query params allowed.
    url = `https://graph.microsoft.com/v1.0${resource}/delta`;
  }

  const data = (await api.call("GET", url)) as {
    value: OutlookEvent[];
    "@odata.nextLink"?: string;
    "@odata.deltaLink"?: string;
  } | null;

  if (!data) {
    // Token expired (410) or resource missing (404) — restart from scratch.
    const newState: SyncState = {
      calendarId,
      min: state.min,
      max: state.max,
      sequence: (state.sequence || 1) + 1,
    };
    return syncOutlookCalendar(api, calendarId, newState);
  }

  // Extract next link (listing or mid-delta pagination) or delta link
  // (delta chain complete for this page).
  const nextLink = data["@odata.nextLink"];
  const deltaLink = data["@odata.deltaLink"];

  const nextState: SyncState = {
    calendarId,
    mode,
    state: nextLink || deltaLink,
    more: !!nextLink,
    min: state.min,
    max: state.max,
    sequence: state.sequence,
  };

  return {
    events: data.value || [],
    state: nextState,
  };
}
