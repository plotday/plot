import type { Channel } from "@plotday/twister/tools/integrations";

export { GOOGLE_PEOPLE_SCOPES } from "./people-api";

// Re-export as CONTACTS_SCOPES for the google composite connector to reference.
export { GOOGLE_PEOPLE_SCOPES as CONTACTS_SCOPES } from "./people-api";

// ---------------------------------------------------------------------------
// Channel listing
// ---------------------------------------------------------------------------

/**
 * Returns the single synthetic "contacts" channel.
 * Google Contacts is channelless — there's only one contacts store.
 */
export async function getContactsChannels(): Promise<Channel[]> {
  return [{ id: "contacts", title: "Contacts" }];
}
