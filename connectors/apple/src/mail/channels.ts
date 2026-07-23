import type { Channel, LinkTypeConfig } from "@plotday/twister/tools/integrations";

import { connectIcloud } from "./imap-fetch";
import type { MailHost } from "./mail-host";

/**
 * Link types for mail threads. Email is status-less (no `statuses[]`), so
 * this type only ever carries the compose/contact-role/copy fields below.
 */
export const MAIL_LINK_TYPES: LinkTypeConfig[] = [
  {
    type: "email",
    // "Thread" (matching Gmail) so the type filter reads "… thread", not
    // "… email". `sourceName` brands the type per-product, so it reads
    // "iCloud email thread" rather than the full connector name.
    label: "Thread",
    sourceName: "iCloud email",
    sharingModel: "thread",
    // A mail mark so email threads don't fall back to the connector's
    // calendar logo. Iconify URLs render crisply at logo size and resolve
    // without a site deploy.
    logo: "https://upload.wikimedia.org/wikipedia/commons/thumb/4/4e/Mail_%28iOS%29.svg/1280px-Mail_%28iOS%29.svg.png",
    logoMono: "https://api.iconify.design/lucide/mail.svg",
    compose: { targets: "addresses" as const },
    contactRoles: [
      { id: "to", label: "To", default: true },
      { id: "cc", label: "CC" },
      { id: "bcc", label: "BCC", hidden: true },
    ],
    composeVerb: "Send",
    replyVerb: "Send",
    replyPlaceholder: "Reply",
    composePlaceholder: "Send an email",
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
