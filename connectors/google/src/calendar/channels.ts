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
  /**
   * True for exactly one calendar per calendarList: the authenticated
   * user's own default calendar (id === their email). Drives the
   * default-enable decision in getChannels.
   */
  primary: boolean;
  /**
   * The user's ACL permission tier on this calendar: "owner", "writer",
   * "reader", or "freeBusyReader". This is a *permission level*, not an
   * ownership signal — a domain admin or a colleague can grant "owner"
   * (full manage-and-share access) on a calendar they don't personally
   * use, e.g. Workspace-wide internal sharing defaults or a teammate
   * sharing their own calendar for scheduling coverage. Do not use this
   * to infer "is this the user's own calendar" — use `primary` instead.
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
    // Per-product brand for aggregate connectors (the Google connector's
    // display name is "Gmail & Calendar"); standalone Google Calendar falls
    // back to its own display name anyway.
    sourceName: "Google Calendar",
    sharingModel: "message" as const,
    compose: { targets: "addresses" as const },
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
 *   defaulting to enabled only for the user's own primary calendar.
 *
 * Deliberately does NOT use `accessRole === "owner"` for this: that ACL tier
 * is granted to anyone with full manage-and-share access on a calendar, not
 * just its actual owner. Workspace domains commonly default internal
 * calendar sharing to "owner", or teammates share their own calendars with
 * each other for scheduling coverage — either way, every other user's
 * personal calendar would also read `accessRole: "owner"` and get swept
 * into the default-enabled set alongside the user's own.
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
    enabledByDefault: c.primary,
  }));
}
