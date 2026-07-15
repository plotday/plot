import {
  getContactsChannels,
  CONTACTS_SCOPES,
} from "@plotday/google-contacts";
import type { Product } from "./product";

export const contactsProduct: Product = {
  key: "contacts",
  requiredScopes: CONTACTS_SCOPES,
  linkTypes: [],
  channelless: true,
  getRawChannels: () => getContactsChannels(),
  // Contacts' lifecycle is handled directly by the Google class (it owns
  // scheduling + the contacts: key namespace), so onChannelEnabled/Disabled
  // intercept the `contacts` product before these are reached — like Calendar.
  onEnable: async () => {
    throw new Error(
      "Contacts onEnable must be handled directly by Google.onChannelEnabled"
    );
  },
  onDisable: async () => {
    throw new Error(
      "Contacts onDisable must be handled directly by Google.onChannelDisabled"
    );
  },
};
