import {
  getGmailChannels,
  GMAIL_MODIFY_SCOPE,
  GMAIL_LINK_TYPES,
} from "../mail/channels";
import type { Product } from "./product";

export const mailProduct: Product = {
  key: "mail",
  requiredScopes: [GMAIL_MODIFY_SCOPE],
  linkTypes: GMAIL_LINK_TYPES,
  getRawChannels: (token) => getGmailChannels(token),
  // Mail's lifecycle is handled directly by the Google class (it owns
  // scheduling + the mail: key namespace), so onChannelEnabled/Disabled
  // intercept the `mail` product before these are reached — mirroring Calendar.
  onEnable: async () => {
    throw new Error(
      "Mail onEnable must be handled directly by Google.onChannelEnabled"
    );
  },
  onDisable: async () => {
    throw new Error(
      "Mail onDisable must be handled directly by Google.onChannelDisabled"
    );
  },
};
