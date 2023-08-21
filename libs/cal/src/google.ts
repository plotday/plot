import { jsonFetch as fetch } from "@worker-tools/json-fetch";

import type {
  CalendarConfig,
  CalendarCredentials,
  Contact,
  Event,
  EventAvailability,
  EventResponse,
  EventStatus,
  EventVisibility,
  Invitee,
  Location,
  RawEvent,
  SyncState,
  WatchState,
} from "./";
import { normalizeName } from "./contact";
import type { calendar_v3 } from "./google-types";

type GoogleEvent = calendar_v3.Schema$Event;
type GoogleAttendee = calendar_v3.Schema$EventAttendee;

function toGoogleDate(d: Date) {
  function pad(n: number) {
    return n < 10 ? "0" + n : n;
  }
  return (
    d.getUTCFullYear() +
    "-" +
    pad(d.getUTCMonth() + 1) +
    "-" +
    pad(d.getUTCDate()) +
    "T" +
    pad(d.getUTCHours()) +
    ":" +
    pad(d.getUTCMinutes()) +
    ":" +
    pad(d.getUTCSeconds()) +
    "Z"
  );
}

class GoogleApi {
  constructor(
    public config: CalendarConfig,
    public credentials: CalendarCredentials
  ) {}

  private async refreshTokens() {
    const payload = {
      client_id: this.config.googleClientId,
      client_secret: this.config.googleOauthSecret,
      refresh_token: this.credentials.refresh_token,
      grant_type: "refresh_token",
    };
    const body = new URLSearchParams(payload);
    const response = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body,
    });
    if (!response.ok) {
      const error = await response.text();
      throw new Error(error);
    }
    const newCredentials = await response.json();
    if (typeof newCredentials === "object") {
      this.credentials = {
        ...this.credentials,
        ...newCredentials,
      };
    }
  }

  public async call(
    method: string,
    url: string,
    params?: { [key: string]: any },
    body?: { [key: string]: any }
  ) {
    const query = params ? `?${new URLSearchParams(params)}` : "";
    let retry = true;
    while (true) {
      const headers = {
        Authorization: `Bearer ${this.credentials.access_token}`,
        Accept: "application/json",
        ...(body ? { "Content-Type": "application/json" } : {}),
      };
      const response = await fetch(url + query, {
        method,
        headers,
        ...(body ? { body } : {}),
      });
      switch (response.status) {
        case 401:
          if (retry) {
            await this.refreshTokens();
            retry = false;
          } else {
            throw new Error(await response.text());
          }
          break;
        case 410:
          // This indicates a full sync is required
          // https://developers.google.com/calendar/api/guides/sync#full_sync_required_by_server
          return null;
        case 200:
          return await response.json();
        default:
          throw new Error(await response.text());
      }
    }
  }
}

export async function sync(
  config: CalendarConfig,
  credentials: CalendarCredentials,
  state: SyncState,
  maxEvents?: number
): Promise<{
  events: RawEvent[];
  credentials: CalendarCredentials;
  state: SyncState;
}> {
  const api = new GoogleApi(config, credentials);

  // https://developers.google.com/calendar/v3/reference/events/list
  const data = (await api.call(
    "GET",
    `https://www.googleapis.com/calendar/v3/calendars/${state.calendarId}/events`,
    {
      ...(state.nextToken && state.more
        ? {
            pageToken: state.nextToken,
          }
        : {}),
      ...(state.nextToken && !state.more
        ? {
            syncToken: state.nextToken,
          }
        : {
            timeMin: toGoogleDate(state.min),
            timeMax: toGoogleDate(state.max),
            orderBy: "startTime",
            singleEvents: true,
          }),
      ...(maxEvents ? { maxResults: maxEvents } : {}),
    }
  )) as {
    items: any[];
    nextPageToken?: string;
    nextSyncToken?: string;
  } | null;

  if (!data) {
    if (state.nextToken) {
      // An incremental sync required a full sync
      const newState = {
        calendarId: state.calendarId,
        min: state.min,
        max: state.max,
        sequence: (state.sequence || 1) + 1,
      };
      return sync(config, credentials, newState, maxEvents);
    } else {
      // This should never happen. Failing to avoid an infinite loop.
      throw new Error("An full sync required another full sync");
    }
  }

  state = {
    ...state,
    nextToken: data.nextPageToken || data.nextSyncToken,
    more: !!data.nextPageToken,
  };
  const events = (data.items || []).map((event: any) => ({
    id: event.id,
    data: event,
  }));
  return {
    events,
    credentials: api.credentials,
    state,
  };
}

export async function watch(
  config: CalendarConfig,
  credentials: CalendarCredentials,
  calendarId: string
): Promise<{
  state: WatchState;
  credentials: CalendarCredentials;
}> {
  const api = new GoogleApi(config, credentials);

  // https://developers.google.com/calendar/api/guides/push
  const watchId = crypto.randomUUID();
  const secret = crypto.randomUUID();
  const data = (await api.call(
    "POST",
    `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events/watch`,
    undefined,
    {
      id: watchId,
      type: "web_hook",
      address: `${config.webhookUrl}/google`,
      token: new URLSearchParams({
        secret,
      }).toString(),
    }
  )) as {
    expiration: string;
  };
  return {
    state: {
      watchId,
      calendarId,
      secret,
      expiry: new Date(parseInt(data.expiration)),
    },
    credentials: api.credentials,
  };
}

export async function deleteWatch(
  config: CalendarConfig,
  credentials: CalendarCredentials,
  watchId: string,
  resourceId: string
) {
  const api = new GoogleApi(config, credentials);
  await api.call(
    "POST",
    "https://www.googleapis.com/calendar/v3/channels/stop",
    {
      id: watchId,
      resourceId,
    }
  );
  return api.credentials;
}

function transformResponse(
  response: string | null | undefined
): EventResponse | undefined {
  switch (response) {
    case "accepted":
      return "accepted";
    case "declined":
      return "declined";
    case "tentative":
      return "tentative";
    default:
      return undefined;
  }
}

export function transform(rawEvent: RawEvent): Event {
  const event: GoogleEvent = rawEvent.data as GoogleEvent;
  const id = rawEvent.id;

  const startString = event.start?.dateTime || event.start?.date;
  const startsAt = startString ? new Date(startString) : undefined;
  const endString = event.end?.dateTime || event.end?.date;
  const endsAt = endString ? new Date(endString) : undefined;

  let organizer: Contact | undefined;
  if (event.organizer?.email) {
    organizer = {
      email: event.organizer.email,
      name: normalizeName(event.organizer.displayName),
    };
  }

  const attendees: GoogleAttendee[] = event.attendees || [];

  let invitees: Invitee[] =
    attendees.reduce((ret, attendee) => {
      if (!attendee.email || attendee.resource) return ret;
      return [
        ...ret,
        {
          email: attendee.email.toLowerCase(),
          name: normalizeName(attendee.displayName),
          response: transformResponse(attendee.responseStatus),
          isOptional: !!attendee.optional,
        },
      ];
    }, [] as Invitee[]) || [];
  if (invitees.length === 0 && event.organizer?.email) {
    invitees = [
      {
        email: event.organizer.email.toLowerCase(),
        name: event.organizer.displayName,
        response: "accepted",
        isOptional: false,
      },
    ];
  }

  let availability: EventAvailability;
  if (event.transparency === "transparent") {
    availability = "free";
  } else {
    switch (event.eventType) {
      case "default":
        availability = "busy";
        break;
      case "outOfOffice":
        availability = "away";
        break;
      case "focusTime":
        availability = "focus";
        break;
      case "workingLocation":
        availability = "location";
        break;
      default:
        availability = "free";
        break;
    }
  }

  let visibility: EventVisibility;
  switch (event.visibility) {
    default:
    case "default":
      visibility = "normal";
      break;
    case "public":
      visibility = "public";
      break;
    case "private":
      visibility = "private";
      break;
    case "confidential":
      visibility = "confidential";
      break;
  }

  let status: EventStatus;
  switch (event.status) {
    default:
    case "confirmed":
      status = "confirmed";
      break;
    case "tentative":
      status = "tentative";
      break;
    case "cancelled":
      status = "cancelled";
      break;
  }

  const conferencingUrl = event.conferenceData?.entryPoints?.[0]?.uri;

  const locations = (
    event.location
      ? [
          {
            name: event.location,
            // TODO: detect addresses
            type: "other",
          } as Location,
        ]
      : []
  ).concat(
    attendees.reduce((ret, attendee) => {
      if (attendee.resource && !attendee.displayName) return ret;
      return [
        ...ret,
        {
          name: attendee.displayName,
          type: "room",
        } as Location,
      ];
    }, [] as Location[]) || []
  );

  return {
    id,
    providerLink: event.htmlLink || undefined,
    series: event.recurringEventId || undefined,
    name: event.summary || undefined,
    status,
    createdAt: event.created ? new Date(event.created) : undefined,
    startsAt,
    endsAt,
    // TODO: strip HTML
    // summary: event.description || undefined,
    description: event.description || undefined,
    availability,
    visibility,
    conferencing: conferencingUrl
      ? {
          url: conferencingUrl,
        }
      : undefined,
    organizer,
    invitees,
    locations,

    // TODO: add categories
    categories: [],
    // TODO: add attachments
    attachments: [],
  };
}

export async function update(
  _config: CalendarConfig,
  _credentials: CalendarCredentials,
  _calendarId: string,
  _eventId: string,
  _changes: Partial<Event>
) {
  throw new Error("Not implemented");
  // const api = new GoogleApi(config, credentials);
  // let googleChanges = {} as GoogleEvent;
  // await api.call(
  //   "PATCH",
  //   `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events/${eventId}`,
  //   undefined,
  //   googleChanges
  // );
}

export async function respond(
  config: CalendarConfig,
  credentials: CalendarCredentials,
  calendarId: string,
  eventId: string,
  response: EventResponse,
  email: string
) {
  const api = new GoogleApi(config, credentials);
  let googleChanges = {} as GoogleEvent;
  googleChanges.attendeesOmitted = true;
  googleChanges.attendees = [
    {
      email,
      responseStatus: response,
    },
  ];
  await api.call(
    "PATCH",
    `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events/${eventId}`,
    undefined,
    googleChanges
  );
}
