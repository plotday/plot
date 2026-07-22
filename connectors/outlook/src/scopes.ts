import type { ScopeConfig, OptionalScopeGroup } from "@plotday/twister";

export const OPTIONAL_SCOPE_GROUPS: OptionalScopeGroup[] = [
  { id: "mail", label: "Mail", default: true,
    scopes: ["https://graph.microsoft.com/Mail.ReadWrite", "https://graph.microsoft.com/Mail.Send"] },
  { id: "calendar", label: "Calendar", default: true,
    scopes: ["https://graph.microsoft.com/Calendars.ReadWrite"] },
  { id: "contacts", label: "Contacts", default: true,
    scopes: ["https://graph.microsoft.com/People.Read", "https://graph.microsoft.com/Contacts.Read"] },
];

// User.Read is required (not part of any toggleable product group): it's the
// permission Graph checks for GET /me, which ensureUserEmailFn calls to
// resolve the connected mailbox's own address — needed for self-sent-message
// detection (mail), organizer matching (calendar), etc. regardless of which
// optional groups the user enables. Without it, /me returns a 403.
export const OUTLOOK_SCOPES: ScopeConfig = {
  required: ["https://graph.microsoft.com/User.Read"],
  optional: OPTIONAL_SCOPE_GROUPS,
};

export interface ProductInfo {
  key: "mail" | "calendar" | "contacts";
  label: string;
  description: string;
  icon: string;
  scopeGroupId: string;
  /**
   * What this product's channels represent (e.g. Outlook Mail's are
   * "folders"). Overrides the connector-level channelNoun in the composite
   * setup UI. Omitted for contacts — its single synthetic channel never
   * renders one.
   */
  channelNoun?: { singular: string; plural: string };
}

export const PRODUCTS: ProductInfo[] = [
  { key: "mail", label: "Outlook Mail", scopeGroupId: "mail",
    description: "Turns email into threads; sends replies and updates flags from Plot.",
    icon: "https://api.iconify.design/simple-icons/microsoftoutlook.svg?color=%230078D4",
    channelNoun: { singular: "folder", plural: "folders" } },
  { key: "calendar", label: "Outlook Calendar", scopeGroupId: "calendar",
    description: "Adds your events to your agenda and writes your RSVPs.",
    icon: "https://api.iconify.design/fluent-emoji/calendar.svg",
    channelNoun: { singular: "calendar", plural: "calendars" } },
  { key: "contacts", label: "Outlook Contacts", scopeGroupId: "contacts",
    description: "Recognizes people by name on your threads.",
    icon: "https://api.iconify.design/material-symbols/contacts.svg" },
];
