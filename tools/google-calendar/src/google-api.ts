import type { Activity } from "@plotday/agent";
import { ActivityType } from "@plotday/agent";

export type GoogleEvent = {
  id: string;
  recurringEventId?: string;
  originalStartTime?: {
    dateTime?: string;
    date?: string;
    timeZone?: string;
  };
  summary?: string;
  description?: string;
  status: "confirmed" | "cancelled" | "tentative";
  start?: {
    dateTime?: string;
    date?: string;
    timeZone?: string;
  };
  end?: {
    dateTime?: string;
    date?: string;
    timeZone?: string;
  };
  recurrence?: string[];
  organizer?: {
    email?: string;
    displayName?: string;
    self?: boolean;
  };
  attendees?: Array<{
    email?: string;
    displayName?: string;
    responseStatus?: "accepted" | "declined" | "tentative" | "needsAction";
    optional?: boolean;
    organizer?: boolean;
    self?: boolean;
    resource?: boolean;
  }>;
  location?: string;
  hangoutLink?: string;
  htmlLink?: string;
  created?: string;
  updated?: string;
};

export type SyncState = {
  calendarId: string;
  state?: string;
  more?: boolean;
  min?: Date;
  max?: Date;
  sequence?: number;
};

export class GoogleApi {
  constructor(public accessToken: string) {}

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
        if ((responseBody as any).status === "FAILED_PRECONDITION") {
          return null;
        }
        throw new Error("Invalid request", { cause: responseBody });
      case 401:
        throw new Error("Authentication failed - token may be expired");
      case 410:
        return null;
      case 200:
        return await response.json();
      default:
        throw new Error(await response.text());
    }
  }
}

export function parseRRule(recurrence?: string[]): string | undefined {
  if (!recurrence?.length) return undefined;

  const rrule = recurrence.find((rule) => rule.startsWith("RRULE:"));
  return rrule ? rrule.substring(6) : undefined; // Remove 'RRULE:' prefix
}

export function parseExDates(recurrence?: string[]): Date[] {
  if (!recurrence?.length) return [];

  return recurrence
    .filter((rule) => rule.startsWith("EXDATE"))
    .flatMap((rule) => {
      const dates = rule.split(":")[1];
      return dates ? dates.split(",").map((d) => new Date(d)) : [];
    });
}

export function parseRDates(recurrence?: string[]): Date[] {
  if (!recurrence?.length) return [];

  return recurrence
    .filter((rule) => rule.startsWith("RDATE"))
    .flatMap((rule) => {
      const dates = rule.split(":")[1];
      return dates ? dates.split(",").map((d) => new Date(d)) : [];
    });
}

export function parseGoogleRecurrenceEnd(
  recurrence?: string[]
): Date | string | null {
  if (!recurrence?.length) return null;

  const rrule = recurrence.find((rule) => rule.startsWith("RRULE:"));
  if (!rrule) return null;

  const untilMatch = rrule.match(/UNTIL=([^;]+)/);
  if (untilMatch) {
    const untilValue = untilMatch[1];
    if (untilValue.includes("T")) {
      const year = untilValue.slice(0, 4);
      const month = untilValue.slice(4, 6);
      const day = untilValue.slice(6, 8);
      const hour = untilValue.slice(9, 11);
      const minute = untilValue.slice(11, 13);
      const second = untilValue.slice(13, 15);
      return new Date(`${year}-${month}-${day}T${hour}:${minute}:${second}Z`);
    } else {
      const year = untilValue.slice(0, 4);
      const month = untilValue.slice(4, 6);
      const day = untilValue.slice(6, 8);
      return `${year}-${month}-${day}`;
    }
  }

  return null;
}

export function parseGoogleRecurrenceCount(
  recurrence?: string[]
): number | null {
  if (!recurrence?.length) return null;

  const rrule = recurrence.find((rule) => rule.startsWith("RRULE:"));
  if (!rrule) return null;

  const countMatch = rrule.match(/COUNT=([^;]+)/);
  if (countMatch) {
    const count = parseInt(countMatch[1]);
    return isNaN(count) ? null : count;
  }

  return null;
}

export function transformGoogleEvent(
  event: GoogleEvent,
  calendarId: string
): Partial<Activity> {
  // Determine if this is an all-day event
  const isAllDay = event.start?.date && !event.start?.dateTime;

  const start = isAllDay
    ? event.start?.date || null // All-day events use date strings
    : event.start?.dateTime
    ? new Date(event.start?.dateTime)
    : null; // Timed events use Date objects

  const end = isAllDay
    ? event.end?.date || null // All-day events use date strings
    : event.end?.dateTime
    ? new Date(event.end?.dateTime)
    : null; // Timed events use Date objects

  const activity: Partial<Activity> = {
    type: isAllDay ? ActivityType.Note : ActivityType.Event,
    title: event.summary || null,
    note: event.description || null,
    start,
    end,
    meta: {
      source: `google-calendar:${event.id}`,
      id: event.id,
      calendarId: calendarId,
      htmlLink: event.htmlLink,
      hangoutLink: event.hangoutLink,
    },
  };

  // Handle recurrence for master events (not instances)
  if (event.recurrence && !event.recurringEventId) {
    activity.recurrenceRule = parseRRule(event.recurrence);

    // Parse recurrence count (takes precedence over UNTIL)
    const recurrenceCount = parseGoogleRecurrenceCount(event.recurrence);
    if (recurrenceCount) {
      activity.recurrenceCount = recurrenceCount;
    } else {
      // Parse recurrence end date for recurring activities if no count
      const recurrenceUntil = parseGoogleRecurrenceEnd(event.recurrence);
      if (recurrenceUntil) {
        activity.recurrenceUntil = recurrenceUntil;
      }
    }

    const exdates = parseExDates(event.recurrence);
    if (exdates.length > 0) {
      activity.recurrenceExdates = exdates;
    }

    const rdates = parseRDates(event.recurrence);
    if (rdates.length > 0) {
      activity.recurrenceDates = rdates;
    }
  }

  return activity;
}

export async function syncGoogleCalendar(
  api: GoogleApi,
  calendarId: string,
  state: SyncState
): Promise<{
  events: GoogleEvent[];
  state: SyncState;
}> {
  const params: any = {
    // Remove singleEvents to get recurring events as masters
    singleEvents: false,
    showDeleted: true,
  };

  if (state.state && state.more) {
    params.pageToken = state.state;
  } else if (state.state && !state.more) {
    params.syncToken = state.state;
  } else {
    params.timeMin = state.min?.toISOString();
  }

  const data = (await api.call(
    "GET",
    `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events`,
    params
  )) as {
    items: GoogleEvent[];
    nextPageToken?: string;
    nextSyncToken?: string;
  } | null;

  if (!data) {
    // Requires full sync
    const newState = {
      calendarId,
      min: state.min,
      max: state.max,
      sequence: (state.sequence || 1) + 1,
    };
    return syncGoogleCalendar(api, calendarId, newState);
  }

  const nextState: SyncState = {
    calendarId,
    state: data.nextPageToken || data.nextSyncToken,
    more: !!data.nextPageToken,
    min: state.min,
    max: state.max,
    sequence: state.sequence,
  };

  return {
    events: data.items || [],
    state: nextState,
  };
}
