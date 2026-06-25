import type { Product } from "./product";
import type { Channel } from "@plotday/twister/tools/integrations";

export const CONTACTS_SCOPES = [
  "https://graph.microsoft.com/people.read",
  "https://graph.microsoft.com/contacts.read",
];

const SYNTHETIC: Channel = { id: "contacts", title: "Contacts", enabledByDefault: true };

export const contactsProduct: Product = {
  key: "contacts",
  requiredScopes: CONTACTS_SCOPES,
  linkTypes: [],
  channelless: true,
  // One synthetic channel so the API-side enabledChannelCount is >=1 when on.
  getRawChannels: async () => [SYNTHETIC],
  // No-op: Outlook has no contacts import. Enabling only grants the enrichment
  // scopes, which Mail's sync reads via token.scopes. seed_default_channels
  // auto-enables this owned synthetic channel on reconnect.
  onEnable: async () => {},
  onDisable: async () => {},
};
