import type {
  Channel,
  LinkTypeConfig,
  StatusIcon,
} from "@plotday/twister/tools/integrations";

import type { CalDAVClient } from "../calendar/caldav";

/** Link type for every reminders-list channel. */
export const REMINDERS_LINK_TYPES: LinkTypeConfig[] = [
  {
    type: "reminder",
    label: "Reminder",
    sourceName: "iCloud Reminders",
    // Personal to-do list, no recipient roster — mirrors Google Tasks.
    sharingModel: "none" as const,
    logo: "https://api.iconify.design/lucide/list-todo.svg",
    logoMono: "https://api.iconify.design/lucide/list-todo.svg",
    statuses: [
      { status: "open", label: "Open", icon: "todo" as StatusIcon },
      { status: "done", label: "Done", done: true, icon: "done" as StatusIcon },
    ],
    supportsAssignee: false,
    compose: { status: "open" },
  },
];

/**
 * List the account's iCloud reminders lists as raw (un-namespaced) channels.
 * The connector namespaces each id with the "reminders" product key.
 * Marks the server-discovered default list `enabledByDefault: true` when one
 * is found; degrades to no default (opt-in-only) otherwise — see
 * `CalDAVClient.discoverDefaultTasksListHref`'s doc for why this is
 * unverified and must fail safe.
 */
export async function getReminderChannels(
  client: CalDAVClient,
  calendarHome: string,
  principalUrl: string
): Promise<Channel[]> {
  const [lists, defaultHref] = await Promise.all([
    client.listCalendarsByComponent(calendarHome, "VTODO"),
    client.discoverDefaultTasksListHref(principalUrl).catch(() => null),
  ]);

  return lists.map((l) => ({
    id: l.href,
    title: l.displayName,
    ...(defaultHref && l.href === defaultHref ? { enabledByDefault: true } : {}),
  }));
}
