import {
  getCalendarChannels,
  CALENDAR_EVENTS_SCOPE,
  CALENDAR_LINK_TYPES,
} from "@plotday/connector-google-calendar";
import type { Product } from "./product";

export const calendarProduct: Product = {
  key: "calendar",
  requiredScopes: [CALENDAR_EVENTS_SCOPE],
  linkTypes: CALENDAR_LINK_TYPES,
  getRawChannels: (token) => getCalendarChannels(token),
  onEnable: async () => {
    // Calendar enable is handled directly by Google.onChannelEnabled
    // (it needs access to the connector instance for callback scheduling).
    // This path should never be reached — Google.onChannelEnabled detects
    // the "calendar:" prefix and calls onCalendarChannelEnabled directly.
    throw new Error(
      "Calendar onEnable must be handled directly by Google.onChannelEnabled"
    );
  },
  onDisable: async () => {
    // Placeholder — calendar disable not yet re-homed.
    throw new Error("Phase 3: calendar disable not yet re-homed");
  },
};
