import type { AuthToken, Channel } from "@plotday/twister/tools/integrations";
import type { LinkTypeConfig, StatusIcon } from "@plotday/twister/tools/integrations";

import { listTaskLists } from "./api";

// ---------------------------------------------------------------------------
// Scope constants
// ---------------------------------------------------------------------------

export const TASKS_SCOPE = "https://www.googleapis.com/auth/tasks";

// ---------------------------------------------------------------------------
// Link types
// ---------------------------------------------------------------------------

export const TASKS_LINK_TYPES: LinkTypeConfig[] = [
  {
    type: "task",
    label: "Task",
    // Per-product brand for aggregate connectors (the Google connector's
    // display name is "Gmail & Calendar"); standalone Google Tasks falls back
    // to its own display name anyway.
    sourceName: "Google Tasks",
    sharingModel: "none" as const,
    // Logo: full-color SVG from static assets (iconify has no logos/google-tasks)
    // logoMono: monochrome version from simple-icons (works fine on iconify)
    logo: "https://plot.day/assets/logo-google-tasks.svg",
    logoMono: "https://api.iconify.design/simple-icons/googletasks.svg",
    statuses: [
      { status: "open", label: "Open", icon: "todo" as StatusIcon },
      { status: "done", label: "Done", done: true, icon: "done" as StatusIcon },
    ],
    supportsAssignee: false,
    compose: { status: "open", todo: true },
  },
];

// ---------------------------------------------------------------------------
// Channel listing
// ---------------------------------------------------------------------------

/**
 * Returns available Google Tasks lists as channel resources for a given token.
 */
export async function getTasksChannels(token: AuthToken): Promise<Channel[]> {
  const lists = await listTaskLists(token.token);
  return lists.map((list) => ({ id: list.id, title: list.title }));
}
