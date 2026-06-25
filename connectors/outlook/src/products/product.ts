import type { AuthToken, Channel, LinkTypeConfig, SyncContext } from "@plotday/twister/tools/integrations";
import { calendarProduct } from "./calendar";
import { mailProduct } from "./mail";
import { contactsProduct } from "./contacts";

/**
 * Interface that each product module (mail, calendar, contacts) must implement.
 *
 * The Outlook connector's lifecycle methods are thin coordinators that:
 *   1. Scope-gate products: only products whose requiredScopes ⊆ token.scopes contribute channels.
 *   2. Namespace channel ids as "<productKey>:<rawId>".
 *   3. Attach per-product linkTypes to each channel.
 *   4. Demux write-backs by the namespaced channelId prefix (or link.type as fallback).
 */
export interface Product {
  /** Stable product key. Also the channel-id prefix and scope group id. */
  key: "mail" | "calendar" | "contacts";

  /**
   * OAuth scopes that must be present in token.scopes for this product to be available.
   * A product whose required scopes are absent contributes no channels.
   */
  requiredScopes: string[];

  /**
   * Link types declared for every channel this product exposes.
   * Attached to channels returned by getChannels so the SDK's dynamic-link-type
   * gate works correctly.
   */
  linkTypes: LinkTypeConfig[];

  /**
   * Set to true for products that expose exactly one synthetic channel (e.g. contacts).
   * The connector passes a single "contacts:contacts" channel in this case.
   */
  channelless?: boolean;

  /**
   * Returns the list of raw (un-prefixed) channels for this product.
   * The connector prefixes each id with the product key before returning to the SDK.
   */
  getRawChannels(token: AuthToken): Promise<Channel[]>;

  /** Called when a channel for this product is enabled by the user. */
  onEnable(rawChannelId: string, context?: SyncContext): Promise<void>;

  /** Called when a channel for this product is disabled by the user. */
  onDisable(rawChannelId: string): Promise<void>;
}

/**
 * Registry of product modules by product key.
 */
export const PRODUCTS_BY_KEY: Record<string, Product> = {
  mail: mailProduct,
  calendar: calendarProduct,
  contacts: contactsProduct,
};
