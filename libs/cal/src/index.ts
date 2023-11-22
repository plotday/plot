import type { Contact, Event, EventResponse } from "./event";
import {
  deleteWatch as deleteGoogleWatch,
  getCalendars as googleGetCalendars,
  getContacts as googleGetContacts,
  respond as googleRespond,
  sync as googleSync,
  transform as googleTransform,
  update as googleUpdate,
  watch as googleWatch,
} from "./google";
import {
  deleteWatch as deleteOutlookWatch,
  getCalendars as outlookGetCalendars,
  getContacts as outlookGetContacts,
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
  email: string;
  access_token: string;
  refresh_token: string;
  scopes: string[];
  updated?: boolean;
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
  state?: string;
};

export type WatchState = {
  watchId: string;
  calendarId: string;
  secret: string;
  expiry: Date;
};

export type ContactSyncState = {
  more?: boolean;
  // If more === true, a page token.
  // Otherwise, a sync token.
  // If unset, a full sync.
  state?: string;
};

export type RawEvent = {
  id: string;
  data: { [key: string]: any };
};

export type Calendar = {
  name: string;
  id: string;
  tz: string;
  primary: boolean;
  account: string;
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
  };
}

export async function deleteWatch(
  config: CalendarConfig,
  credentials: CalendarCredentials,
  watchId: string,
  // Required for google, but not outlook
  resourceId?: string
): Promise<{
  credentials: CalendarCredentials;
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
  isOrganizer: boolean
) {
  switch (credentials.provider) {
    case "google":
      return await googleRespond(
        config,
        credentials,
        calendarId,
        eventId,
        response
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

export async function getCalendars(
  config: CalendarConfig,
  credentials: CalendarCredentials
): Promise<{
  calendars: Calendar[];
  credentials: CalendarCredentials;
}> {
  switch (credentials.provider) {
    case "google":
      return await googleGetCalendars(config, credentials);
    case "outlook":
      return await outlookGetCalendars(config, credentials);
    default:
      throw new Error(`Unknown provider: ${credentials.provider}`);
  }
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
  switch (credentials.provider) {
    case "google":
      return await googleGetContacts(config, credentials, state);
    case "outlook":
      return await outlookGetContacts(config, credentials, state);
    default:
      throw new Error(`Unknown provider: ${credentials.provider}`);
  }
}
