import type { ScopeConfig, OptionalScopeGroup } from "@plotday/twister";

export const OPTIONAL_SCOPE_GROUPS: OptionalScopeGroup[] = [
  { id: "mail", label: "Mail", default: true,
    scopes: ["https://graph.microsoft.com/mail.readwrite", "https://graph.microsoft.com/mail.send"] },
  { id: "calendar", label: "Calendar", default: true,
    scopes: ["https://graph.microsoft.com/calendars.readwrite"] },
  { id: "contacts", label: "Contacts", default: true,
    scopes: ["https://graph.microsoft.com/people.read", "https://graph.microsoft.com/contacts.read"] },
];

export const OUTLOOK_SCOPES: ScopeConfig = { required: [], optional: OPTIONAL_SCOPE_GROUPS };

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
