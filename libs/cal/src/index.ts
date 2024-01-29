import type { Contact, Event, EventResponse } from "./event";
import * as google from "./google";
import * as outlook from "./outlook";

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

export function getCalendarConfig(env: {
  readonly GOOGLE_CLIENT_ID: string;
  readonly GOOGLE_OAUTH_SECRET: string;
  readonly MICROSOFT_CLIENT_ID: string;
  readonly MICROSOFT_OAUTH_SECRET: string;
  readonly CALENDAR_WEBHOOK_URL: string;
}): CalendarConfig {
  return {
    googleClientId: env.GOOGLE_CLIENT_ID,
    googleOauthSecret: env.GOOGLE_OAUTH_SECRET,
    outlookClientId: env.MICROSOFT_CLIENT_ID,
    outlookOauthSecret: env.MICROSOFT_OAUTH_SECRET,
    webhookUrl: env.CALENDAR_WEBHOOK_URL,
  };
}

export async function getCredentials(
  config: CalendarConfig,
  provider: CalendarProvider,
  code: string
): Promise<CalendarCredentials> {
  switch (provider) {
    case "google":
      return await google.getCredentials(config, code);
    case "outlook":
    default:
      throw new Error("Not implemented");
    // return await getCredentials(config, email, code);
  }
}

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
      ret = await google.watch(config, credentials, calendarId);
      break;
    case "outlook":
      ret = await outlook.watch(config, credentials, calendarId, renew);
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
      newCredentials = await google.deleteWatch(
        config,
        credentials,
        watchId,
        resourceId
      );
      break;
    case "outlook":
      newCredentials = await outlook.deleteWatch(config, credentials, watchId);
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
      return await google.sync(config, credentials, state, maxEvents);
    case "outlook":
      return await outlook.sync(config, credentials, state, maxEvents);
    default:
      throw new Error(`Unknown provider: ${credentials.provider}`);
  }
}

export function transform(provider: CalendarProvider, event: RawEvent): Event {
  switch (provider) {
    case "google":
      return google.transform(event);
    case "outlook":
      return outlook.transform(event);
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
      return await google.update(
        config,
        credentials,
        calendarId,
        eventId,
        changes
      );
    case "outlook":
      return await outlook.update(
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
      return await google.respond(
        config,
        credentials,
        calendarId,
        eventId,
        response
      );
    case "outlook":
      return await outlook.respond(
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
      return await google.getCalendars(config, credentials);
    case "outlook":
      return await outlook.getCalendars(config, credentials);
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
      return await google.getContacts(config, credentials, state);
    case "outlook":
      return await outlook.getContacts(config, credentials, state);
    default:
      throw new Error(`Unknown provider: ${credentials.provider}`);
  }
}
