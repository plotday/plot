import type { ScopeConfig, OptionalScopeGroup } from "@plotday/twister";

/**
 * Per-product optional scope groups.
 *
 * Scope strings are hardcoded here rather than imported from the individual
 * connector packages to keep this package self-contained without pulling in
 * those heavy dependencies at Phase 2 scaffolding time.
 *
 * Source references:
 *   mail:      Gmail.SCOPES in @plotday/connector-gmail
 *   calendar:  GoogleCalendar.EVENTS_SCOPE + CALENDAR_LIST_SCOPE in @plotday/connector-google-calendar
 *   tasks:     GoogleTasks.SCOPES in @plotday/connector-google-tasks
 *   contacts:  GOOGLE_PEOPLE_SCOPES in @plotday/google-contacts
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
    scopes: ["https://www.googleapis.com/auth/gmail.modify"],
    default: true,
  },
  {
    id: "calendar",
    label: "Calendar",
    scopes: [
      "https://www.googleapis.com/auth/calendar.events",
      "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    ],
    default: true,
  },
  {
    id: "tasks",
    label: "Tasks",
    scopes: ["https://www.googleapis.com/auth/tasks"],
    default: true,
  },
  {
    id: "contacts",
    label: "Contacts",
    // TODO Phase 3: People scopes are shared with mail/calendar enrichment — reconcile sharing.
    scopes: [
      "https://www.googleapis.com/auth/contacts.readonly",
      "https://www.googleapis.com/auth/contacts.other.readonly",
    ],
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
  },
  {
    key: "calendar",
    label: "Google Calendar",
    description: "Adds your events to your agenda and writes your RSVPs.",
    icon: "https://api.iconify.design/logos/google-calendar.svg",
    scopeGroupId: "calendar",
  },
  {
    key: "tasks",
    label: "Google Tasks",
    description: "Syncs your to-do lists — reads, creates, and completes tasks.",
    icon: "https://plot.day/assets/logo-google-tasks.svg",
    scopeGroupId: "tasks",
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
