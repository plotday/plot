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
    throw new Error("Phase 3: calendar sync not yet re-homed");
  },
  onDisable: async () => {
    throw new Error("Phase 3: calendar sync not yet re-homed");
  },
};
