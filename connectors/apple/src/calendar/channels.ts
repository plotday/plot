import type {
  Channel,
  LinkTypeConfig,
  StatusIcon,
} from "@plotday/twister/tools/integrations";

import { CalDAVClient } from "./caldav";

/** Link types for every calendar channel (moved off the connector class). */
export const CALENDAR_LINK_TYPES: LinkTypeConfig[] = [
  {
    type: "event",
    label: "Event",
    sourceName: "iCloud Calendar",
    sharingModel: "thread",
    includesSchedules: true,
    // The three iCalendar STATUS values the sync maps onto every event link
    // (`prepareEvent` in apple.ts: CONFIRMED/TENTATIVE, and Cancelled for a
    // cancellation). Declaring them is what gives the app a label, an icon
    // and a filter entry for each — an emitted status with no matching entry
    // here has none of those. "Confirmed" is `hiddenDefault` because the
    // overwhelming majority of events carry it, so it would otherwise add a
    // status chip to every single event.
    statuses: [
      {
        status: "Confirmed",
        label: "Confirmed",
        icon: "confirmed" as StatusIcon,
        hiddenDefault: true,
      },
      { status: "Tentative", label: "Tentative", icon: "tentative" as StatusIcon },
      { status: "Cancelled", label: "Cancelled", icon: "cancelled" as StatusIcon },
    ],
    // Attendee participation, matching the roles the sync derives from each
    // ATTENDEE's ROLE parameter. Organizer membership is tracked separately
    // on schedule_contact.role and isn't exposed as a thread-level role.
    contactRoles: [
      { id: "required", label: "Required", default: true },
      { id: "optional", label: "Optional" },
    ],
    // Crisp, high-contrast calendar mark; the previous rounded-square SVG was
    // mostly white with thin red strokes and washed out at logo size. Served
    // from plot.day rather than hotlinked from a third-party wiki, so the
    // artwork can't move or be rate-limited out from under clients.
    logo: "https://plot.day/assets/logo-icloud-calendar.png",
    logoMono: "https://api.iconify.design/lucide/calendar.svg",
    // `supportsContactChanges` is deliberately NOT set (unlike the mail link
    // type): the CalDAV write-back path only updates the owner's own ATTENDEE
    // PARTSTAT — their RSVP. It cannot add or remove attendees on an event, so
    // offering roster editing here would accept changes that never reach the
    // calendar. Enabling it requires an ATTENDEE add/remove PUT first.
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
