import type {
  AuthToken,
  Channel,
  LinkTypeConfig,
} from "@plotday/twister/tools/integrations";

import {
  OUTLOOK_CALENDAR_LINK_TYPES,
  OUTLOOK_CALENDAR_SCOPE,
  getOutlookCalendarChannels,
} from "./calendar/channels";
import {
  OUTLOOK_MAIL_LINK_TYPES,
  OUTLOOK_MAIL_SCOPES,
  getOutlookMailChannels,
} from "./mail/channels";

/**
 * A product offered by this connector (mail, calendar, contacts).
 *
 * This is metadata only. The connector's lifecycle methods are thin
 * coordinators that:
 *   1. Scope-gate products: only products whose requiredScopes ⊆ token.scopes
 *      contribute channels.
 *   2. Namespace channel ids as "<productKey>:<rawId>".
 *   3. Attach per-product linkTypes to each channel.
 *
 * Enable/disable lifecycle is NOT part of this interface: `Outlook` handles
 * every product key directly in `onChannelEnabled`/`onChannelDisabled`,
 * because each needs the connector instance for callback scheduling and
 * key-namespaced storage.
 */
export interface Product {
  /** Stable product key. Also the channel-id prefix and scope group id. */
  key: "mail" | "calendar" | "contacts";

  /**
   * OAuth scopes that must be present in token.scopes for this product to be
   * available. A product whose required scopes are absent contributes no
   * channels.
   */
  requiredScopes: string[];

  /**
   * Link types declared for every channel this product exposes.
   * Attached to channels returned by getChannels so the SDK's dynamic-link-type
   * gate works correctly.
   */
  linkTypes: LinkTypeConfig[];

  /**
   * Set to true for products that expose exactly one synthetic channel (e.g.
   * contacts). The connector passes a single "contacts:contacts" channel in
   * this case.
   */
  channelless?: boolean;

  /**
   * Returns the list of raw (un-prefixed) channels for this product.
   * The connector prefixes each id with the product key before returning to
   * the SDK.
   */
  getRawChannels(token: AuthToken): Promise<Channel[]>;
}

export const CONTACTS_SCOPES = [
  "https://graph.microsoft.com/People.Read",
  "https://graph.microsoft.com/Contacts.Read",
];

const SYNTHETIC_CONTACTS_CHANNEL: Channel = {
  id: "contacts",
  title: "Contacts",
  enabledByDefault: true,
};

export const mailProduct: Product = {
  key: "mail",
  requiredScopes: OUTLOOK_MAIL_SCOPES,
  linkTypes: OUTLOOK_MAIL_LINK_TYPES,
  getRawChannels: (token) => getOutlookMailChannels(token),
};

export const calendarProduct: Product = {
  key: "calendar",
  requiredScopes: [OUTLOOK_CALENDAR_SCOPE],
  linkTypes: OUTLOOK_CALENDAR_LINK_TYPES,
  getRawChannels: (token) => getOutlookCalendarChannels(token),
};

export const contactsProduct: Product = {
  key: "contacts",
  requiredScopes: CONTACTS_SCOPES,
  linkTypes: [],
  channelless: true,
  // Outlook has no contacts IMPORT. Enabling the synthetic channel only
  // signals the intent to grant the People.Read / Contacts.Read scopes, which
  // Mail's sync reads via `token.scopes` to enrich sender display names (see
  // enrichLinkContactsFromOutlook). One synthetic channel so the API-side
  // enabledChannelCount is >= 1 when on; seed_default_channels auto-enables it
  // on reconnect.
  getRawChannels: async () => [SYNTHETIC_CONTACTS_CHANNEL],
};

/**
 * Registry of products by product key.
 */
export const PRODUCTS_BY_KEY: Record<string, Product> = {
  mail: mailProduct,
  calendar: calendarProduct,
  contacts: contactsProduct,
};
