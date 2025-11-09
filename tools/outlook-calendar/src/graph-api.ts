import type { NewActivity } from "@plotday/twister";
import { ActivityType } from "@plotday/twister";
import type { Calendar } from "@plotday/twister/common/calendar";

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
      response?: "none" | "organizer" | "tentativelyAccepted" | "accepted" | "declined" | "notResponded";
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
  state?: string; // deltaToken or deltaLink
  more?: boolean;
  min?: Date;
  max?: Date;
  sequence?: number;
};

/**
 * Microsoft Graph API client for calendar operations
 */
export class GraphApi {
  constructor(public accessToken: string) {}

  /**
   * Make a request to Microsoft Graph API
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

    const response = await fetch(url + query, {
      method,
      headers,
      ...(body ? { body: JSON.stringify(body) } : {}),
    });

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
    const resource = calendarId === "primary"
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
    console.warn(`Non-UTC timezone ${dateValue.timeZone} may need special handling`);
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
export function parseOutlookRRule(recurrence: OutlookEvent["recurrence"]): string | undefined {
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
  if ((pattern?.type === "absoluteYearly" || pattern?.type === "relativeYearly") && pattern.month) {
    rrule += `;BYMONTH=${pattern.month}`;
  }

  // Add UNTIL or COUNT from range
  if (range?.type === "endDate" && range.endDate) {
    // Convert date to RRULE format (YYYYMMDD or YYYYMMDDTHHmmssZ)
    const endDate = range.endDate.replace(/[-:]/g, "").replace(/\.\d{3}Z?$/, "Z");
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
export function parseOutlookExDates(_recurrence?: OutlookEvent["recurrence"]): Date[] {
  // Microsoft Graph represents exceptions as separate events, not as EXDATE
  // Exception events have type="exception" and seriesMasterId pointing to the master event
  return [];
}

/**
 * Parse additional recurrence dates (RDATE) from Outlook events
 * Note: Microsoft Graph doesn't support RDATE in the recurrence pattern.
 * This function exists for API compatibility but returns empty array.
 */
export function parseOutlookRDates(_recurrence?: OutlookEvent["recurrence"]): Date[] {
  // Microsoft Graph doesn't support RDATE in recurrence patterns
  return [];
}

/**
 * Parse recurrence end date/time from Microsoft Graph recurrence
 */
export function parseOutlookRecurrenceEnd(recurrence?: OutlookEvent["recurrence"]): Date | string | null {
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
export function parseOutlookRecurrenceCount(recurrence?: OutlookEvent["recurrence"]): number | null {
  if (!recurrence?.range) return null;

  const range = recurrence.range;

  if (range.type === "numbered" && range.numberOfOccurrences) {
    const count = parseInt(range.numberOfOccurrences.toString());
    return isNaN(count) ? null : count;
  }

  return null;
}

/**
 * Transform Microsoft Graph event to Plot Activity
 */
export function transformOutlookEvent(
  event: OutlookEvent,
  calendarId: string
): NewActivity | null {
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

  // Create base activity
  const activity: NewActivity = {
    type: isAllDay ? ActivityType.Note : ActivityType.Event,
    title: event.subject || null,
    note: event.body?.content || null,
    noteType: event.body?.contentType === "html" ? "html" : "text",
    start,
    end,
    meta: {
      source: `outlook-calendar:${event.id}`,
      id: event.id,
      calendarId: calendarId,
      webLink: event.webLink,
      onlineMeetingUrl: event.onlineMeeting?.joinUrl,
      iCalUId: event.iCalUId,
    },
  };

  // Handle recurrence for master events (not instances or exceptions)
  if (event.recurrence && event.type === "seriesMaster") {
    activity.recurrenceRule = parseOutlookRRule(event.recurrence);

    // Parse recurrence count (takes precedence over UNTIL)
    const recurrenceCount = parseOutlookRecurrenceCount(event.recurrence);
    if (recurrenceCount) {
      activity.recurrenceCount = recurrenceCount;
    } else {
      // Parse recurrence end date if no count
      const recurrenceUntil = parseOutlookRecurrenceEnd(event.recurrence);
      if (recurrenceUntil) {
        activity.recurrenceUntil = recurrenceUntil;
      }
    }

    // Parse exception dates (currently not available from Graph API directly)
    const exdates = parseOutlookExDates(event.recurrence);
    if (exdates.length > 0) {
      activity.recurrenceExdates = exdates;
    }

    // Parse additional recurrence dates (not supported by Graph API)
    const rdates = parseOutlookRDates(event.recurrence);
    if (rdates.length > 0) {
      activity.recurrenceDates = rdates;
    }
  }

  // Handle exception events (modifications to recurring event instances)
  if (event.type === "exception" && event.seriesMasterId && event.originalStart) {
    // This is a modified instance of a recurring event
    const originalStartDate = new Date(event.originalStart);
    activity.occurrence = originalStartDate;
    // The seriesMasterId links this to the master recurring event
    // This will need to be matched to the master activity in the Plot system
    if (activity.meta) {
      activity.meta.seriesMasterId = event.seriesMasterId;
    }
  }

  return activity;
}

/**
 * Sync calendar events using Microsoft Graph delta query
 */
export async function syncOutlookCalendar(
  api: GraphApi,
  calendarId: string,
  state: SyncState
): Promise<{
  events: OutlookEvent[];
  state: SyncState;
}> {
  let url: string;

  // If we have a delta link (full URL with token), use it directly
  if (state.state && state.state.startsWith("http")) {
    url = state.state;
  } else if (state.state) {
    // We have a delta token, append it to the URL
    const resource = calendarId === "primary"
      ? "/me/events"
      : `/me/calendars/${calendarId}/events`;
    url = `https://graph.microsoft.com/v1.0${resource}/delta?$deltatoken=${state.state}`;
  } else {
    // Initial sync - use delta query without token
    const resource = calendarId === "primary"
      ? "/me/events"
      : `/me/calendars/${calendarId}/events`;

    const params: string[] = [];

    // Add time filter if specified
    if (state.min) {
      params.push(`$filter=start/dateTime ge '${state.min.toISOString()}'`);
    }

    const queryString = params.length > 0 ? `?${params.join("&")}` : "";
    url = `https://graph.microsoft.com/v1.0${resource}/delta${queryString}`;
  }

  const data = (await api.call("GET", url)) as {
    value: OutlookEvent[];
    "@odata.nextLink"?: string;
    "@odata.deltaLink"?: string;
  } | null;

  if (!data) {
    // Delta token expired or sync failed, need full sync
    const newState: SyncState = {
      calendarId,
      min: state.min,
      max: state.max,
      sequence: (state.sequence || 1) + 1,
    };
    return syncOutlookCalendar(api, calendarId, newState);
  }

  // Extract next link or delta link
  const nextLink = data["@odata.nextLink"];
  const deltaLink = data["@odata.deltaLink"];

  const nextState: SyncState = {
    calendarId,
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
