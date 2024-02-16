import jwt from "@tsndr/cloudflare-worker-jwt";
import { jsonFetch as fetch } from "@worker-tools/json-fetch";
import type { calendar_v3, people_v1 } from "googleapis";

import type {
  Calendar,
  CalendarConfig,
  CalendarCredentials,
  Contact,
  ContactSyncState,
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

type GoogleEvent = calendar_v3.Schema$Event;
type GoogleAttendee = calendar_v3.Schema$EventAttendee;
type GoogleContact = people_v1.Schema$Person;

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
        updated: true,
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
      ...(state.state && state.more
        ? {
            pageToken: state.state,
          }
        : {}),
      ...(state.state && !state.more
        ? {
            syncToken: state.state,
          }
        : {
            timeMin: toGoogleDate(state.min),
            timeMax: toGoogleDate(state.max),
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
    if (state.state) {
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
      throw new Error("A full sync required another full sync");
    }
  }

  state = {
    ...state,
    state: data.nextPageToken ?? data.nextSyncToken,
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

function transformResponse(response: string | null | undefined): EventResponse {
  switch (response) {
    case "accepted":
      return "accepted";
    case "declined":
      return "declined";
    case "tentative":
      return "tentative";
    default:
      return null;
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

  let organizerFound = false;
  let invitees: Invitee[] =
    attendees.reduce((ret, attendee) => {
      if (!attendee.email || attendee.resource) return ret;
      if (attendee.email === organizer?.email) organizerFound = true;
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
  // This happens when attendees are hidden
  if (!organizerFound && organizer) {
    invitees.push({
      email: organizer.email,
      name: organizer.name,
      response: "accepted",
      isOptional: false,
    });
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
    inviteesHidden: event.guestsCanSeeOtherGuests === false,
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
  response: EventResponse
) {
  const api = new GoogleApi(config, credentials);
  let googleChanges = {} as GoogleEvent;
  googleChanges.attendeesOmitted = true;
  googleChanges.attendees = [
    {
      email: credentials.email,
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

export async function getCalendars(
  config: CalendarConfig,
  credentials: CalendarCredentials
): Promise<{
  calendars: Calendar[];
  credentials: CalendarCredentials;
}> {
  if (
    !credentials.scopes?.some?.((scope) =>
      [
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
      ].includes(scope)
    )
  ) {
    return {
      calendars: [
        {
          name: "Primary",
          id: credentials.email,
          primary: true,
          tz: "America/New_York",
          account: credentials.email,
        },
      ],
      credentials,
    };
  }

  const api = new GoogleApi(config, credentials);
  const response = await api.call(
    "GET",
    "https://www.googleapis.com/calendar/v3/users/me/calendarList",
    undefined
  );
  return {
    calendars: (response as any).items.map((item: any) => ({
      name: item.summary,
      id: item.id,
      primary: !!item.primary,
      tz: item.timeZone,
      account: credentials.email,
    })),
    credentials,
  };
}

type ContactTokens = {
  connections?: {
    nextPageToken?: string;
    nextSyncToken?: string;
  };
  other?: {
    nextPageToken?: string;
    nextSyncToken?: string;
  };
};

function parseContact(contact: GoogleContact) {
  const name = contact.names?.[0]?.displayName;
  const avatar = contact.photos?.filter(
    (p) => !p.default && p.metadata?.primary
  )?.[0]?.url;
  return { name, avatar };
}

export async function getContacts(
  config: CalendarConfig,
  credentials: CalendarCredentials,
  state: ContactSyncState
): Promise<{
  contacts: Contact[];
  credentials: CalendarCredentials;
  state: ContactSyncState;
}> {
  const api = new GoogleApi(config, credentials);
  let tokens = JSON.parse(state.state ?? "{}") as ContactTokens;
  const contacts = {} as Record<string, Contact>;
  let more = false;

  // If we're starting a new sync, or there are more pages in a connection sync
  if (!state.more || tokens.connections?.nextPageToken) {
    if (
      credentials.scopes?.some?.(
        (scope) => scope === "https://www.googleapis.com/auth/contacts.readonly"
      )
    ) {
      const response = (await api.call(
        "GET",
        "https://people.googleapis.com/v1/people/me/connections",
        {
          requestSyncToken: true,
          ...(tokens.connections?.nextPageToken
            ? {
                pageToken: tokens.connections?.nextPageToken,
              }
            : tokens.connections?.nextSyncToken
            ? {
                syncToken: tokens.connections?.nextSyncToken,
              }
            : {}),
          personFields: "names,emailAddresses,photos",
        }
      )) as people_v1.Schema$ListConnectionsResponse;
      for (const c of response.connections ?? []) {
        for (const e of c.emailAddresses ?? []) {
          if (!e.value) continue;
          const { name, avatar } = parseContact(c);
          contacts[e.value] = {
            ...contacts[e.value],
            email: e.value,
            ...(name ? { name } : {}),
            ...(avatar ? { avatar } : {}),
          };
        }
      }
      more = true;
      tokens = {
        ...tokens,
        connections: {
          nextPageToken: response.nextPageToken ?? undefined,
          nextSyncToken: response.nextSyncToken ?? undefined,
        },
      };
    } else {
      more = true;
      tokens = {
        ...tokens,
        connections: {},
      };
    }
  } else {
    if (
      credentials.scopes?.some?.(
        (scope) =>
          scope === "https://www.googleapis.com/auth/contacts.other.readonly"
      )
    ) {
      const response = (await api.call(
        "GET",
        "https://people.googleapis.com/v1/otherContacts",
        {
          requestSyncToken: true,
          ...(tokens.other?.nextPageToken
            ? {
                pageToken: tokens.other?.nextPageToken,
              }
            : tokens.other?.nextSyncToken
            ? {
                syncToken: tokens.other?.nextSyncToken,
              }
            : {}),
          readMask: "names,emailAddresses,photos",
        }
      )) as people_v1.Schema$ListOtherContactsResponse;
      for (const c of response.otherContacts ?? []) {
        for (const e of c.emailAddresses ?? []) {
          if (!e.value) continue;
          const { name, avatar } = parseContact(c);
          contacts[e.value] = {
            ...contacts[e.value],
            email: e.value,
            ...(name ? { name } : {}),
            ...(avatar ? { avatar } : {}),
          };
        }
      }
      more = !!response.nextPageToken;
      tokens = {
        ...tokens,
        other: {
          nextPageToken: response.nextPageToken ?? undefined,
          nextSyncToken: response.nextSyncToken ?? undefined,
        },
      };
    } else {
      more = false;
      tokens = {
        ...tokens,
        other: {},
      };
    }
  }

  return {
    contacts: Object.values(contacts),
    credentials,
    state: {
      more,
      state: JSON.stringify(tokens),
    },
  };
}

export async function getCredentials(
  config: CalendarConfig,
  code: string
): Promise<CalendarCredentials> {
  if (!config.authCallbackUrl) {
    throw new Error("Missing authCallbackUrl");
  }
  const payload = {
    client_id: config.googleClientId,
    client_secret: config.googleOauthSecret,
    code,
    grant_type: "authorization_code",
    redirect_uri: config.authCallbackUrl,
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
  const creds = await response.json();
  if (creds === null || typeof creds !== "object") {
    throw new Error("Invalid response");
  }
  if (!("id_token" in creds)) {
    throw new Error("Missing ID token");
  }
  if (!("access_token" in creds)) {
    throw new Error("Missing access token");
  }
  if (!("refresh_token" in creds)) {
    throw new Error("Missing refresh token");
  }
  if (!("scope" in creds)) {
    throw new Error("Missing scopes");
  }

  const token = jwt.decode(creds.id_token as string);
  const email = token.payload?.email;
  if (!email) {
    throw new Error("Missing email");
  }

  return {
    ...creds,
    access_token: creds.access_token as string,
    refresh_token: creds.refresh_token as string,
    scopes: (creds.scope as string).split(" "),
    provider: "google",
    email,
  };
}
