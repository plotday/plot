import type { Channel, LinkTypeConfig } from "@plotday/twister/tools/integrations";

/**
 * Link types for mail threads. Plan 3 fills in statuses/compose; declared now
 * so the composite's product registry is complete.
 */
export const MAIL_LINK_TYPES: LinkTypeConfig[] = [
  {
    type: "email",
    label: "Email",
    sharingModel: "thread",
  },
];

/**
 * Mail channels. Stub until Plan 3 wires IMAP mailbox enumeration; returns no
 * channels so the mail product contributes nothing yet.
 */
export async function getMailChannels(): Promise<Channel[]> {
  return [];
}
