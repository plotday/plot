import {
  getCalendarChannels,
  CALENDAR_EVENTS_SCOPE,
  CALENDAR_LINK_TYPES,
} from "../calendar/channels";
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
    // Calendar disable is handled directly by Google.onChannelDisabled
    // (it needs access to the connector instance for callback scheduling and
    // state teardown). This path should never be reached — Google.onChannelDisabled
    // detects the "calendar:" prefix and calls stopCalendarSync directly.
    throw new Error(
      "Calendar onDisable must be handled directly by Google.onChannelDisabled"
    );
  },
};
