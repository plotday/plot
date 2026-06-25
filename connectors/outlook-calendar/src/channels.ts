import type { AuthToken, Channel } from "@plotday/twister/tools/integrations";
import type { LinkTypeConfig } from "@plotday/twister/tools/integrations";

import { GraphApi } from "./graph-api";

// ---------------------------------------------------------------------------
// Scope constants
// ---------------------------------------------------------------------------

export const OUTLOOK_CALENDAR_SCOPE =
  "https://graph.microsoft.com/calendars.readwrite";

// ---------------------------------------------------------------------------
// Calendar type
// ---------------------------------------------------------------------------

export type Calendar = {
  id: string;
  name: string;
  description: string | null;
  primary: boolean;
};

// ---------------------------------------------------------------------------
// Link types
// ---------------------------------------------------------------------------

export const OUTLOOK_CALENDAR_LINK_TYPES: LinkTypeConfig[] = [
  {
    type: "event",
    label: "Event",
    sharingModel: "thread" as const,
    includesSchedules: true,
    logo: "https://api.iconify.design/logos/microsoft-icon.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/microsoftoutlook.svg?color=%230078D4",
    logoMono: "https://api.iconify.design/simple-icons/microsoftoutlook.svg",
  },
];

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------

/**
 * Returns available Outlook calendars as channel resources for a given token.
 */
export async function getOutlookCalendarChannels(
  token: AuthToken
): Promise<Channel[]> {
  const api = new GraphApi(token.token);
  const calendars = await api.getCalendars();
  return calendars.map((c) => ({ id: c.id, title: c.name }));
}
