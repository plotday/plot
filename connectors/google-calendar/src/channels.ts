import type { AuthToken, Channel } from "@plotday/twister/tools/integrations";
import type { StatusIcon } from "@plotday/twister/tools/integrations";
import type { LinkTypeConfig } from "@plotday/twister/tools/integrations";

import { GoogleApi } from "./google-api";

// ---------------------------------------------------------------------------
// Scope constants
// ---------------------------------------------------------------------------

export const CALENDAR_EVENTS_SCOPE =
  "https://www.googleapis.com/auth/calendar.events";

export const CALENDAR_LIST_SCOPE =
  "https://www.googleapis.com/auth/calendar.calendarlist.readonly";

// ---------------------------------------------------------------------------
// Calendar type
// ---------------------------------------------------------------------------

export type Calendar = {
  id: string;
  name: string;
  description: string | null;
  primary: boolean;
  /**
   * The user's access level on this calendar: "owner", "writer", "reader",
   * or "freeBusyReader". Calendars the user owns (their primary + any
   * secondary calendars they created) are "owner"; subscribed holiday/
   * birthday calendars and someone-else's shared calendars are "reader"/
   * "writer". Drives the default-enable decision in getChannels.
   */
  accessRole: string | null;
};

// ---------------------------------------------------------------------------
// Link types
// ---------------------------------------------------------------------------

export const CALENDAR_LINK_TYPES: LinkTypeConfig[] = [
  {
    type: "event",
    label: "Event",
    sharingModel: "thread" as const,
    includesSchedules: true,
    logo: "https://api.iconify.design/logos/google-calendar.svg",
    logoMono: "https://api.iconify.design/simple-icons/googlecalendar.svg",
    statuses: [
      { status: "Confirmed", label: "Confirmed", icon: "confirmed" as StatusIcon, hiddenDefault: true },
      { status: "Tentative", label: "Tentative", icon: "tentative" as StatusIcon },
      { status: "Cancelled", label: "Cancelled", icon: "cancelled" as StatusIcon },
    ],
    // Attendee participation. Organizer membership is tracked separately
    // on schedule_contact.role and isn't exposed as a thread-level role.
    contactRoles: [
      { id: "required", label: "Required", default: true },
      { id: "optional", label: "Optional" },
    ],
  },
];

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------

/**
 * Fetches the authenticated user's calendar list via the Google Calendar API.
 * Requires CALENDAR_LIST_SCOPE.
 */
export async function listCalendars(api: GoogleApi): Promise<Calendar[]> {
  const data = (await api.call(
    "GET",
    "https://www.googleapis.com/calendar/v3/users/me/calendarList"
  )) as {
    items: Array<{
      id: string;
      summary: string;
      description?: string;
      primary?: boolean;
      accessRole?: string;
    }>;
  };

  return data.items.map((item) => ({
    id: item.id,
    name: item.summary,
    description: item.description || null,
    accessRole: item.accessRole ?? null,
    primary: item.primary || false,
  }));
}

/**
 * Returns available calendars as channel resources for a given token.
 *
 * - If CALENDAR_LIST_SCOPE is absent, returns a single "primary" fallback
 *   channel (avoids a 403 from calling calendarList without the scope).
 * - Otherwise calls the calendarList API and maps each calendar to a channel,
 *   defaulting to enabled only for calendars the user owns (accessRole "owner").
 */
export async function getCalendarChannels(token: AuthToken): Promise<Channel[]> {
  if (!token.scopes.includes(CALENDAR_LIST_SCOPE)) {
    return [{ id: "primary", title: "Calendar", enabledByDefault: true }];
  }
  const api = new GoogleApi(token.token);
  const calendars = await listCalendars(api);
  return calendars.map((c) => ({
    id: c.id,
    title: c.name,
    enabledByDefault: c.accessRole === "owner",
  }));
}
