import type {
  AuthToken,
  Channel,
  LinkTypeConfig,
} from "@plotday/twister/tools/integrations";
import { CONTACTS_SCOPES, getContactsChannels } from "@plotday/google-contacts";

import {
  CALENDAR_EVENTS_SCOPE,
  CALENDAR_LINK_TYPES,
  getCalendarChannels,
} from "./calendar/channels";
import {
  GMAIL_LINK_TYPES,
  GMAIL_MODIFY_SCOPE,
  getGmailChannels,
} from "./mail/channels";
import {
  TASKS_LINK_TYPES,
  TASKS_SCOPE,
  getTasksChannels,
} from "./tasks/channels";

/**
 * A product offered by this connector (mail, calendar, tasks, contacts).
 *
 * This is metadata only. The connector's lifecycle methods are thin
 * coordinators that:
 *   1. Scope-gate products: only products whose requiredScopes ⊆ token.scopes
 *      contribute channels.
 *   2. Namespace channel ids as "<productKey>:<rawId>".
 *   3. Attach per-product linkTypes to each channel.
 *
 * Enable/disable lifecycle is NOT part of this interface: `Google` handles
 * every product key directly in `onChannelEnabled`/`onChannelDisabled`,
 * because each needs the connector instance for callback scheduling and
 * key-namespaced storage.
 */
export interface Product {
  /** Stable product key. Also the channel-id prefix and scope group id. */
  key: "mail" | "calendar" | "tasks" | "contacts";

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

export const mailProduct: Product = {
  key: "mail",
  requiredScopes: [GMAIL_MODIFY_SCOPE],
  linkTypes: GMAIL_LINK_TYPES,
  getRawChannels: (token) => getGmailChannels(token),
};

export const calendarProduct: Product = {
  key: "calendar",
  requiredScopes: [CALENDAR_EVENTS_SCOPE],
  linkTypes: CALENDAR_LINK_TYPES,
  getRawChannels: (token) => getCalendarChannels(token),
};

export const tasksProduct: Product = {
  key: "tasks",
  requiredScopes: [TASKS_SCOPE],
  linkTypes: TASKS_LINK_TYPES,
  getRawChannels: (token) => getTasksChannels(token),
};

export const contactsProduct: Product = {
  key: "contacts",
  requiredScopes: CONTACTS_SCOPES,
  linkTypes: [],
  channelless: true,
  getRawChannels: () => getContactsChannels(),
};

/**
 * Registry of products by product key.
 */
export const PRODUCTS_BY_KEY: Record<string, Product> = {
  mail: mailProduct,
  calendar: calendarProduct,
  tasks: tasksProduct,
  contacts: contactsProduct,
};
