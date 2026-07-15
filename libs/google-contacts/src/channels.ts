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
 *
 * `enabledByDefault: true` forces this channel on when a connection is first
 * added. Without it the client's default-channel heuristic
 * (ChannelDefaultSuggester) treats any channel titled "Contacts" as a
 * low-value informational channel — a rule meant for Google's "Contacts'
 * birthdays" calendar — and silently de-selects it, leaving the granted
 * Contacts product disabled. The explicit hint overrides that heuristic, the
 * same way Gmail (INBOX/SENT) and Calendar (primary) declare their defaults.
 */
export async function getContactsChannels(): Promise<Channel[]> {
  return [{ id: "contacts", title: "Contacts", enabledByDefault: true }];
}
