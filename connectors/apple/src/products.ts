import type { Channel, LinkTypeConfig } from "@plotday/twister/tools/integrations";

import { CALENDAR_LINK_TYPES } from "./calendar/channels";
import { MAIL_LINK_TYPES } from "./mail/channels";

/**
 * A product offered by the Apple composite connector. Unlike google there are
 * no OAuth scopes — availability is gated on credentials being present, which
 * the connector checks before composing. This interface is metadata + a raw
 * channel enumerator; enable/disable lifecycle is handled by the `Apple` class
 * per product key (it needs the connector instance for scheduling + storage).
 */
export interface AppleProduct {
  key: "calendar" | "mail";
  linkTypes: LinkTypeConfig[];
  getRawChannels(): Promise<Channel[]>;
}

/**
 * Build the product list. The connector injects the per-product channel
 * enumerators (calendar needs a live CalDAV client + calendar home; mail is a
 * stub for now), keeping this registry free of connector internals.
 */
export function appleProducts(opts: {
  getCalendarChannels: () => Promise<Channel[]>;
  getMailChannels: () => Promise<Channel[]>;
}): AppleProduct[] {
  return [
    {
      key: "calendar",
      linkTypes: CALENDAR_LINK_TYPES,
      getRawChannels: opts.getCalendarChannels,
    },
    {
      key: "mail",
      linkTypes: MAIL_LINK_TYPES,
      getRawChannels: opts.getMailChannels,
    },
  ];
}
