import type { AuthenticationProvider } from "@microsoft/microsoft-graph-client";
import { Client } from "@microsoft/microsoft-graph-client";
import type {
  DateTimeTimeZone,
  Event as OutlookEvent,
} from "@microsoft/microsoft-graph-types";
import { jsonFetch as fetch } from "@worker-tools/json-fetch";

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
  LocationType,
  RawEvent,
  SyncState,
  WatchState,
} from "./";
import { normalizeName } from "./contact";

function fromMsDate(date?: DateTimeTimeZone | null) {
  if (!date) return undefined;
  if (date.timeZone && date.timeZone !== "UTC") {
    throw new Error(`Unsupported timezone ${date.timeZone}`);
  }
  let d = date.dateTime;
  if (!d) return undefined;
  if (d[d.length - 1] !== "Z") {
    d = d + "Z";
  }
  return new Date(d);
}

class Auth implements AuthenticationProvider {
  static readonly TOKEN_URL =
    "https://login.microsoftonline.com/common/oauth2/v2.0/token";

  constructor(
    private clientId: string,
    private clientSecret: string,
    public credentials: any
  ) {}

  /**
   * This method is called before every request.
   */
  public async getAccessToken(): Promise<string> {
    if (
      !this.credentials.expires_at ||
      new Date(this.credentials.expires_at) < new Date()
    ) {
      await this.refreshTokens();
    }
    return this.credentials.access_token;
  }

  private async refreshTokens() {
    const payload = {
      client_id: this.clientId,
      client_secret: this.clientSecret,
      refresh_token: this.credentials.refresh_token,
      grant_type: "refresh_token",
    };
    const body = new URLSearchParams(payload);
    const tokenResponse = await fetch(
      Auth.TOKEN_URL + "?" + new URLSearchParams(payload),
      {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body,
      }
    );

    const data = await tokenResponse.json();
    if (!tokenResponse.ok) {
      if (data) {
        console.error(data);
        if (typeof data === "object" && "error_description" in data) {
          console.error(data.error_description);
        }
      }
      throw new Error("Failed to refresh token", { cause: data });
    }
    if (data && typeof data === "object") {
      let newCredentials = data;
      let expires_in = 3914;
      if ("expires_in" in data && typeof data.expires_in === "number") {
        ({ expires_in, ...newCredentials } = data);
      }
      this.credentials = {
        ...this.credentials,
        ...newCredentials,
        expires_at: new Date(Date.now() + expires_in * 1000).toISOString(),
      };
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
  const authProvider = new Auth(
    config.outlookClientId,
    config.outlookOauthSecret,
    credentials
  );
  const client = Client.initWithMiddleware({ authProvider });

  const response = await client
    .api(
      state?.state ??
        `${
          state.calendarId === "primary"
            ? "/me"
            : `/users/${state.calendarId}/calendar`
        }/calendarview/delta?startDateTime=${state.min.toISOString()}&endDateTime=${state.max.toISOString()}`
    )
    .header("Prefer", `odata.maxpagesize=${maxEvents || 250}`)
    .get();

  const events: RawEvent[] = [];
  const seriesMasters: { [id: string]: OutlookEvent } = {};
  for (let outlookEvent of response.value) {
    if (!outlookEvent.id) {
      // ignore
    } else if (outlookEvent.type === "seriesMaster") {
      seriesMasters[outlookEvent.id] = outlookEvent;
    } else {
      if (outlookEvent.seriesMasterId) {
        if (seriesMasters[outlookEvent.seriesMasterId]) {
          outlookEvent = {
            ...seriesMasters[outlookEvent.seriesMasterId],
            ...outlookEvent,
          };
        } else {
          throw Error(`Missing series master ${outlookEvent.seriesMasterId}`);
        }
      }
      const rawEvent = {
        id: outlookEvent.id,
        data: outlookEvent,
      };
      events.push(rawEvent);
    }
  }

  state = {
    ...(state || {}),
    state: response["@odata.nextLink"] || response["@odata.deltaLink"],
    more: !!response["@odata.nextLink"],
  };

  return {
    events,
    credentials: authProvider.credentials,
    state,
  };
}

export async function watch(
  config: CalendarConfig,
  credentials: CalendarCredentials,
  calendarId: string,
  renew?: { watchId: string; watchSecret: string }
): Promise<{
  state: WatchState;
  credentials: CalendarCredentials;
}> {
  const authProvider = new Auth(
    config.outlookClientId,
    config.outlookOauthSecret,
    credentials
  );
  const client = Client.initWithMiddleware({ authProvider });

  const expiry = new Date(Date.now() + 4_230 * 60 * 1000);

  let watchId, secret;
  if (renew) {
    watchId = renew.watchId;
    secret = renew.watchSecret;
    const renewal = {
      expirationDateTime: expiry.toISOString(),
    };
    try {
      await client.api(`/beta/subscriptions/${watchId}`).patch(renewal);
    } catch (e) {
      console.error("Failed to renew watch; recreating", e);
      return watch(config, credentials, calendarId);
    }
  } else {
    secret = crypto.randomUUID();
    const subscription = {
      changeType: "created,updated,deleted",
      notificationUrl: `${config.webhookUrl}/outlook`,
      resource: `${
        calendarId === "primary" ? "/me" : `/users/${calendarId}`
      }/events`,
      clientState: secret,
      // Required, with the limit defined here:
      // https://learn.microsoft.com/en-us/graph/api/resources/subscription?view=graph-rest-1.0
      expirationDateTime: expiry.toISOString(),
    };

    ({ id: watchId } = await client.api("/subscriptions").post(subscription));
  }

  return {
    state: {
      watchId,
      calendarId,
      secret,
      expiry,
    },
    credentials: authProvider.credentials,
  };
}

export async function deleteWatch(
  config: CalendarConfig,
  credentials: CalendarCredentials,
  watchId: string
) {
  const authProvider = new Auth(
    config.outlookClientId,
    config.outlookOauthSecret,
    credentials
  );
  const client = Client.initWithMiddleware({ authProvider });

  await client.api(`/subscriptions/${watchId}`).delete();
  return authProvider.credentials;
}

function transformResponse(response: string | null | undefined): EventResponse {
  switch (response) {
    case "organizer":
    case "accepted":
      return "accepted";
    case "declined":
      return "declined";
    case "tentativelyAccepted":
      return "tentative";
    default:
      return null;
  }
}

export function transform(rawEvent: RawEvent, accountEmail: string): Event {
  const event: OutlookEvent = rawEvent.data;
  const id = rawEvent.id;

  const startsAt = fromMsDate(event.start);
  const endsAt = fromMsDate(event.end);

  let organizerEmail: string | undefined = undefined;
  let organizer: Contact | undefined;
  if (event.organizer?.emailAddress?.address) {
    organizerEmail = event.organizer?.emailAddress?.address?.toLowerCase?.();
    organizer = {
      email: organizerEmail,
      name: normalizeName(event.organizer.emailAddress.name),
    };
  }

  let response: EventResponse = event.responseStatus
    ? transformResponse(event.responseStatus.response)
    : "accepted";
  let isOptional = false;
  let organizerFound = organizerEmail === accountEmail;
  const invitees: Invitee[] =
    event.attendees?.reduce?.((ret, attendee) => {
      const email = attendee.emailAddress?.address?.toLowerCase();
      if (!email || attendee.type === "resource") return ret;
      const isOrganizer = email === organizerEmail;
      if (isOrganizer) organizerFound = true;
      const inviteeResponse = isOrganizer
        ? "accepted"
        : transformResponse(attendee.status?.response);
      const inviteeOptional = attendee.type === "optional";
      if (email.toLowerCase() === accountEmail.toLowerCase()) {
        response = inviteeResponse;
        isOptional = inviteeOptional;
        return ret;
      }
      return [
        ...ret,
        {
          email,
          name: normalizeName(attendee.emailAddress?.name),
          response: inviteeResponse,
          isOptional: inviteeOptional,
        } as Invitee,
      ];
    }, [] as Invitee[]) || [];
  if (!organizerFound && organizerEmail) {
    invitees.push({
      email: organizerEmail,
      name: normalizeName(event.organizer?.emailAddress?.name),
      response: "accepted" as EventResponse,
    });
  }

  let availability: EventAvailability;
  switch (event.showAs) {
    case "busy":
    case "tentative":
      availability = "busy";
      break;
    case "oof":
      availability = "away";
      break;
    case "workingElsewhere":
      availability = "location";
      break;
    default:
      availability = "free";
      break;
  }

  let visibility: EventVisibility;
  switch (event.sensitivity) {
    default:
    case "normal":
      visibility = "normal";
      break;
    case "personal":
      visibility = "personal";
      break;
    case "private":
      visibility = "private";
      break;
    case "confidential":
      visibility = "confidential";
      break;
  }

  let status: EventStatus = "confirmed";
  if (event.isCancelled) status = "cancelled";
  if (event.showAs === "tentative") status = "tentative";

  const conferencingUrl = event.onlineMeetingUrl;

  const locations: Location[] =
    event.locations
      ?.filter((location) => location.displayName || location.address)
      .map((location) => {
        let type: LocationType;
        if (location.locationType === "conferenceRoom") {
          type = "room";
        } else if (event.location?.address) {
          type = "address";
        } else {
          type = "other";
        }
        return {
          name:
            location.displayName ||
            location.address?.street ||
            "Unknown location",
          type,
        };
      }) || [];

  return {
    id,
    providerLink: event.webLink || undefined,
    series: event.seriesMasterId || undefined,
    name: event.subject || undefined,
    status,
    response,
    isOptional,
    createdAt: event.createdDateTime
      ? new Date(event.createdDateTime)
      : undefined,
    startsAt,
    endsAt,
    summary: event.bodyPreview || undefined,
    description: event.body?.content || undefined,
    availability,
    visibility,
    conferencing: conferencingUrl
      ? {
          url: conferencingUrl,
        }
      : undefined,
    organizer,
    invitees,
    inviteesHidden: !!event.hideAttendees,
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
}

export async function respond(
  config: CalendarConfig,
  credentials: CalendarCredentials,
  calendarId: string,
  eventId: string,
  response: EventResponse,
  isOrganizer: boolean
) {
  const authProvider = new Auth(
    config.outlookClientId,
    config.outlookOauthSecret,
    credentials
  );
  const client = Client.initWithMiddleware({ authProvider });

  // Outlook does not support organizer responses
  if (isOrganizer) return;

  // Outlook deletes declined events, so we only tentatively accept
  await client
    .api(
      `/me/calendars/${calendarId}/events/${eventId}/${
        response === "accepted" ? "accept" : "tentativelyAccept"
      }`
    )
    .post({});
}

export async function getCalendars(
  _config: CalendarConfig,
  credentials: CalendarCredentials
): Promise<{
  calendars: Calendar[];
  credentials: CalendarCredentials;
}> {
  return {
    calendars: [
      {
        name: credentials.email,
        id: "primary",
        primary: true,
        account: credentials.email,
        tz: "America/New_York", // TODO FIXME
      },
    ],
    credentials,
  };
}

export async function getContacts(
  _config: CalendarConfig,
  credentials: CalendarCredentials,
  state: ContactSyncState
): Promise<{
  contacts: Contact[];
  credentials: CalendarCredentials;
  state: ContactSyncState;
}> {
  // TODO
  // const authProvider = new Auth(
  //   config.outlookClientId,
  //   config.outlookOauthSecret,
  //   credentials
  // );
  // const client = Client.initWithMiddleware({ authProvider });
  // const response = await client.api("/me/contacts").get();
  // return {
  //   contacts: response.value.map((contact: any) => ({
  //     email: contact.emailAddresses[0].address,
  //     name: contact.displayName,
  //   })),
  //   credentials,
  //   state,
  // };
  return {
    contacts: [],
    credentials,
    state,
  };
}
