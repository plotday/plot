import type { Channel, LinkTypeConfig } from "@plotday/twister/tools/integrations";

import { connectIcloud } from "./imap-fetch";
import type { MailHost } from "./mail-host";

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
 * INBOX is the single enabled mail channel in v1. The Sent mailbox is read
 * implicitly during sync (for the owner's own replies), not offered as its own
 * channel; broader multi-folder selection is a follow-up.
 */
export async function getMailChannels(host: MailHost): Promise<Channel[]> {
  const session = await connectIcloud(host);
  try {
    const boxes = await host.imap.listMailboxes(session);
    const hasInbox = boxes.some((b) => b.name.toUpperCase() === "INBOX");
    if (!hasInbox) return [];
    return [{ id: "INBOX", title: "Inbox", enabledByDefault: true }];
  } finally {
    await host.imap.disconnect(session);
  }
}
