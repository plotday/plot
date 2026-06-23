import {
  getContactsChannels,
  CONTACTS_SCOPES,
} from "@plotday/connector-google-contacts";
import type { Product } from "./product";

export const contactsProduct: Product = {
  key: "contacts",
  requiredScopes: CONTACTS_SCOPES,
  linkTypes: [],
  channelless: true,
  getRawChannels: () => getContactsChannels(),
  onEnable: async () => {
    throw new Error("Phase 3: contacts sync not yet re-homed");
  },
  onDisable: async () => {
    throw new Error("Phase 3: contacts sync not yet re-homed");
  },
};
