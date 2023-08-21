import type { Event, EventResponse } from "./event";
import {
  deleteWatch as deleteGoogleWatch,
  respond as googleRespond,
  sync as googleSync,
  transform as googleTransform,
  update as googleUpdate,
  watch as googleWatch,
} from "./google";
import {
  deleteWatch as deleteOutlookWatch,
  respond as outlookRespond,
  sync as outlookSync,
  transform as outlookTransform,
  update as outlookUpdate,
  watch as outlookWatch,
} from "./outlook";

export type {
  Event,
  EventStatus,
  EventResponse,
  EventVisibility,
  EventAvailability,
  Attachment,
  Invitee,
  Contact,
  Conferencing,
  Location,
  LocationType,
} from "./event";

export type { ChangeNotification as OutlookChangeNotification } from "@microsoft/microsoft-graph-types";

export type CalendarConfig = {
  googleClientId: string;
  googleOauthSecret: string;
  outlookClientId: string;
  outlookOauthSecret: string;
  webhookUrl?: string;
};

export type CalendarProvider = "google" | "outlook";

export type CalendarCredentials = {
  provider: CalendarProvider;
  access_token: string;
  refresh_token: string;
};

export type SyncState = {
  calendarId: string;
  min: Date;
  max: Date;
  sequence?: number;
  more?: boolean;
  // If more === true, a page token.
  // Otherwise, a sync token.
  // If unset, a full sync.
  nextToken?: string;
};

export type WatchState = {
  watchId: string;
  calendarId: string;
  secret: string;
  expiry: Date;
};

export type RawEvent = {
  id: string;
  data: { [key: string]: any };
};

export async function watch(
  config: CalendarConfig,
  credentials: CalendarCredentials,
  calendarId: string,
  renew?: {
    watchId: string;
    watchSecret: string;
  }
): Promise<{
  state: WatchState;
  credentials: CalendarCredentials;
  credentialsChanged: boolean;
}> {
  if (!config.webhookUrl) throw new Error("Missing webhookUrl");
  let ret;
  switch (credentials.provider) {
    case "google":
      ret = await googleWatch(config, credentials, calendarId);
      break;
    case "outlook":
      ret = await outlookWatch(config, credentials, calendarId, renew);
      break;
    default:
      throw new Error(`Unknown provider: ${credentials.provider}`);
  }
  return {
    ...ret,
    credentialsChanged: !credentialsEqual(credentials, ret.credentials),
  };
}

export function credentialsEqual(
  c1: CalendarCredentials,
  c2: CalendarCredentials
): boolean {
  return (
    c1.provider === c2.provider &&
    c1.access_token === c2.access_token &&
    c1.refresh_token === c2.refresh_token
  );
}

export async function deleteWatch(
  config: CalendarConfig,
  credentials: CalendarCredentials,
  watchId: string,
  // Required for google, but not outlook
  resourceId?: string
): Promise<{
  credentials: CalendarCredentials;
  credentialsChanged: boolean;
}> {
  let newCredentials: CalendarCredentials;
  switch (credentials.provider) {
    case "google":
      if (!resourceId) throw new Error("Missing resourceId");
      newCredentials = await deleteGoogleWatch(
        config,
        credentials,
        watchId,
        resourceId
      );
      break;
    case "outlook":
      newCredentials = await deleteOutlookWatch(config, credentials, watchId);
      break;
    default:
      throw new Error(`Unknown provider: ${credentials.provider}`);
  }
  return {
    credentials: newCredentials,
    credentialsChanged: !credentialsEqual(credentials, newCredentials),
  };
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
  if (!state.sequence) state.sequence = 1;
  switch (credentials.provider) {
    case "google":
      return await googleSync(config, credentials, state, maxEvents);
    case "outlook":
      return await outlookSync(config, credentials, state, maxEvents);
    default:
      throw new Error(`Unknown provider: ${credentials.provider}`);
  }
}

export function transform(provider: CalendarProvider, event: RawEvent): Event {
  switch (provider) {
    case "google":
      return googleTransform(event);
    case "outlook":
      return outlookTransform(event);
    default:
      throw new Error(`Unknown provider: ${provider}`);
  }
}

export async function update(
  config: CalendarConfig,
  credentials: CalendarCredentials,
  calendarId: string,
  eventId: string,
  changes: Partial<Event>
) {
  switch (credentials.provider) {
    case "google":
      return await googleUpdate(
        config,
        credentials,
        calendarId,
        eventId,
        changes
      );
    case "outlook":
      return await outlookUpdate(
        config,
        credentials,
        calendarId,
        eventId,
        changes
      );
    default:
      throw new Error(`Unknown provider: ${credentials.provider}`);
  }
}

export async function respond(
  config: CalendarConfig,
  credentials: CalendarCredentials,
  calendarId: string,
  eventId: string,
  response: EventResponse,
  email: string,
  isOrganizer: boolean
) {
  switch (credentials.provider) {
    case "google":
      return await googleRespond(
        config,
        credentials,
        calendarId,
        eventId,
        response,
        email
      );
    case "outlook":
      return await outlookRespond(
        config,
        credentials,
        calendarId,
        eventId,
        response,
        isOrganizer
      );
    default:
      throw new Error(`Unknown provider: ${credentials.provider}`);
  }
}
