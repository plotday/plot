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
 *   contacts:  GOOGLE_PEOPLE_SCOPES in @plotday/connector-google-contacts
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

export const PRODUCTS: ProductInfo[] = [
  {
    key: "mail",
    label: "Gmail",
    description: "Send and receive email, track threads for follow-up.",
    icon: "https://api.iconify.design/logos/google-gmail.svg",
    scopeGroupId: "mail",
  },
  {
    key: "calendar",
    label: "Google Calendar",
    description: "See your calendar events and respond to invitations.",
    icon: "https://api.iconify.design/logos/google-calendar.svg",
    scopeGroupId: "calendar",
  },
  {
    key: "tasks",
    label: "Google Tasks",
    description: "Manage your Google Tasks to-do items in Plot.",
    icon: "https://api.iconify.design/logos/google-tasks.svg",
    scopeGroupId: "tasks",
  },
  {
    key: "contacts",
    label: "Google Contacts",
    description: "Enrich threads with contact names and photos from your Google contacts.",
    icon: "https://api.iconify.design/logos/google-contacts.svg",
    scopeGroupId: "contacts",
  },
];
