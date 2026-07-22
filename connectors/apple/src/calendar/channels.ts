import type { Channel, LinkTypeConfig } from "@plotday/twister/tools/integrations";

import { CalDAVClient } from "./caldav";

/** Link types for every calendar channel (moved off the connector class). */
export const CALENDAR_LINK_TYPES: LinkTypeConfig[] = [
  {
    type: "event",
    label: "Event",
    sourceName: "iCloud Calendar",
    sharingModel: "thread",
    includesSchedules: true,
    // Crisp, high-contrast calendar mark; the previous rounded-square SVG was
    // mostly white with thin red strokes and washed out at logo size.
    logo: "https://api.iconify.design/fluent-emoji-flat/calendar.svg",
    logoMono: "https://api.iconify.design/lucide/calendar.svg",
  },
];

/**
 * List the account's iCloud calendars as raw (un-namespaced) channels.
 * The connector namespaces each id with the "calendar" product key.
 */
export async function getCalendarChannels(
  client: CalDAVClient,
  calendarHome: string
): Promise<Channel[]> {
  const calendars = await client.listCalendars(calendarHome);
  return calendars.map((c) => ({ id: c.href, title: c.displayName }));
}
