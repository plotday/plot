import type { ScopeConfig, OptionalScopeGroup } from "@plotday/twister";
import { CONTACTS_SCOPES } from "@plotday/google-contacts";

import {
  CALENDAR_EVENTS_SCOPE,
  CALENDAR_LIST_SCOPE,
} from "./calendar/channels";
import { GMAIL_MODIFY_SCOPE } from "./mail/channels";
import { TASKS_SCOPE } from "./tasks/channels";

/**
 * Per-product optional scope groups.
 *
 * Each group's scopes are imported from the product that needs them, so the
 * consent screen can't drift from what the product's API calls actually
 * require.
 *
 * Each group id MUST equal the product key (mail|calendar|tasks|contacts)
 * so that the channel-id prefix, scope group id, and product key are the
 * same string everywhere (a three-way invariant).
 */

// TODO Phase 3: People scopes are shared with mail/calendar enrichment — reconcile sharing.

export const OPTIONAL_SCOPE_GROUPS: OptionalScopeGroup[] = [
  {
    id: "mail",
    label: "Mail",
    scopes: [GMAIL_MODIFY_SCOPE],
    default: true,
  },
  {
    id: "calendar",
    label: "Calendar",
    scopes: [CALENDAR_EVENTS_SCOPE, CALENDAR_LIST_SCOPE],
    default: true,
  },
  {
    id: "tasks",
    label: "Tasks",
    scopes: [TASKS_SCOPE],
    default: true,
  },
  {
    id: "contacts",
    label: "Contacts",
    // TODO Phase 3: People scopes are shared with mail/calendar enrichment — reconcile sharing.
    scopes: [...CONTACTS_SCOPES],
    default: true,
  },
];

export const GOOGLE_SCOPES: ScopeConfig = {
  required: [],
  optional: OPTIONAL_SCOPE_GROUPS,
};

/** Product metadata for UI rendering. key === scopeGroupId (three-way invariant). */
export interface ProductInfo {
  key: "mail" | "calendar" | "tasks" | "contacts";
  label: string;
  description: string;
  icon: string;
  /** Must equal key — validated in tests. */
  scopeGroupId: string;
  /**
   * What this product's channels represent (e.g. Gmail's are "labels").
   * Overrides the connector-level channelNoun in the composite setup UI.
   * Omitted for contacts — its single synthetic channel never renders one.
   */
  channelNoun?: { singular: string; plural: string };
}

// Descriptions intentionally fold each product's scope-reason (what access is
// requested and why) into one short line, rather than listing scopes/access
// separately. Keep them brief.
//
// Icons: Gmail/Calendar use the iconify multicolor brand marks; Tasks uses
// Plot's hosted brand asset (no iconify `logos:google-tasks`); Contacts uses a
// Material contacts glyph (no Google Contacts brand mark exists on iconify —
// swap for a hosted brand asset if one is added, like Tasks).
export const PRODUCTS: ProductInfo[] = [
  {
    key: "mail",
    label: "Gmail",
    description: "Turns email into threads; sends replies and updates labels from Plot.",
    icon: "https://api.iconify.design/logos/google-gmail.svg",
    scopeGroupId: "mail",
    channelNoun: { singular: "label", plural: "labels" },
  },
  {
    key: "calendar",
    label: "Google Calendar",
    description: "Adds your events to your agenda and writes your RSVPs.",
    icon: "https://api.iconify.design/logos/google-calendar.svg",
    scopeGroupId: "calendar",
    channelNoun: { singular: "calendar", plural: "calendars" },
  },
  {
    key: "tasks",
    label: "Google Tasks",
    description: "Syncs your to-do lists — reads, creates, and completes tasks.",
    icon: "https://plot.day/assets/logo-google-tasks.svg",
    scopeGroupId: "tasks",
    channelNoun: { singular: "task list", plural: "task lists" },
  },
  {
    key: "contacts",
    label: "Google Contacts",
    description: "Recognizes people by name and photo on your threads.",
    // Hosted on plot.day/assets like the Tasks logo (mirrored from the brand
    // PNG). Goes live with the next apps/site deploy.
    icon: "https://plot.day/assets/logo-google-contacts.png",
    scopeGroupId: "contacts",
  },
];
