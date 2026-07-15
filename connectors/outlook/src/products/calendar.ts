import { getOutlookCalendarChannels, OUTLOOK_CALENDAR_SCOPE, OUTLOOK_CALENDAR_LINK_TYPES } from "../calendar/channels";
import type { Product } from "./product";

export const calendarProduct: Product = {
  key: "calendar",
  requiredScopes: [OUTLOOK_CALENDAR_SCOPE],
  linkTypes: OUTLOOK_CALENDAR_LINK_TYPES,
  getRawChannels: (token) => getOutlookCalendarChannels(token),
  onEnable: async () => { throw new Error("Calendar onEnable handled by Outlook.onChannelEnabled"); },
  onDisable: async () => { throw new Error("Calendar onDisable handled by Outlook.onChannelDisabled"); },
};
