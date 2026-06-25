import { getOutlookMailChannels, OUTLOOK_MAIL_SCOPES, OUTLOOK_MAIL_LINK_TYPES } from "@plotday/connector-outlook-mail";
import type { Product } from "./product";

export const mailProduct: Product = {
  key: "mail",
  requiredScopes: OUTLOOK_MAIL_SCOPES,
  linkTypes: OUTLOOK_MAIL_LINK_TYPES,
  getRawChannels: (token) => getOutlookMailChannels(token),
  onEnable: async () => { throw new Error("Mail onEnable handled by Outlook.onChannelEnabled"); },
  onDisable: async () => { throw new Error("Mail onDisable handled by Outlook.onChannelDisabled"); },
};
