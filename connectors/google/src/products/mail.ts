import {
  getGmailChannels,
  GMAIL_MODIFY_SCOPE,
  GMAIL_LINK_TYPES,
} from "@plotday/connector-gmail";
import type { Product } from "./product";

export const mailProduct: Product = {
  key: "mail",
  requiredScopes: [GMAIL_MODIFY_SCOPE],
  linkTypes: GMAIL_LINK_TYPES,
  getRawChannels: (token) => getGmailChannels(token),
  onEnable: async () => {
    throw new Error("Phase 3: mail sync not yet re-homed");
  },
  onDisable: async () => {
    throw new Error("Phase 3: mail sync not yet re-homed");
  },
};
