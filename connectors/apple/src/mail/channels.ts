import type { Channel, LinkTypeConfig } from "@plotday/twister/tools/integrations";
import type { ImapMailbox } from "@plotday/twister/tools/imap";

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
    // The connector's word for a note on this thread, so in-thread composer
    // copy reads "Add a reply" (matching Gmail) rather than "Add a note".
    noteLabel: "Reply",
    // Email addresses each message, not the conversation: every note carries
    // its own recipient set (`transform.ts` populates one per message) and the
    // thread roster is their union. So someone brought in halfway through sees
    // the reply that added them and everything after it — not the exchange
    // that preceded them.
    sharingModel: "message",
    // …and the flip side: recipients can be added or dropped on an existing
    // thread. `write.ts` resolves each reply's recipients from the note's own
    // access list (falling back to the original message's headers), so those
    // mid-thread edits are honoured on the way out.
    supportsContactChanges: true,
    // A mail mark so email threads don't fall back to the connector's
    // calendar logo. Served from plot.day rather than hotlinked from a
    // third-party wiki, so the artwork can't move or be rate-limited out
    // from under every client rendering an email thread.
    logo: "https://plot.day/assets/logo-icloud-mail.png",
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
    // The connector round-trips file attachments in both directions (outbound
    // via SMTP, inbound via IMAP part fetch), so surface the "Attach file"
    // button on the composer/reply.
    supportsFileAttachments: true,
    // onCreateLink reconstructs a real forward (original message +
    // attachments) when `CreateLinkDraft.forward` is set, so the runtime
    // should route native forwards here instead of the blockquote fallback.
    supportsForward: true,
  },
];

/**
 * Special-use attributes excluded from channel enumeration. Sent is excluded
 * because it is read implicitly during INBOX's sync pass (see sync.ts)
 * rather than synced as a channel of its own — offering it separately would
 * let a folder's pass see Sent messages in isolation, reintroducing the
 * split-recompute regression `transformMessages` guards against. Drafts,
 * Trash, and Junk have no sync value. Archive, All, and Flagged are
 * deliberately NOT excluded — an Archive mailbox (or similar) is the whole
 * point of this feature.
 */
const EXCLUDED_SPECIAL_USE = new Set(["\\Sent", "\\Drafts", "\\Trash", "\\Junk"]);

/** Render a mailbox's hierarchical `name` as a human-readable path, e.g. "Archive / 2024". */
function mailboxTitle(box: ImapMailbox): string {
  if (box.name.toUpperCase() === "INBOX") return "Inbox";
  return box.name.split(box.delimiter || "/").join(" / ");
}

/**
 * Every selectable IMAP mailbox becomes its own channel. INBOX is the only one
 * enabled by default; the rest are opt-in. Sent is excluded because it is read
 * implicitly during INBOX's sync pass (see sync.ts) rather than synced as a
 * channel of its own — and Drafts/Trash/Junk have no sync value.
 */
export async function getMailChannels(host: MailHost): Promise<Channel[]> {
  const session = await connectIcloud(host);
  try {
    const boxes = await host.imap.listMailboxes(session);
    return boxes
      .filter((b) => !b.flags.includes("\\Noselect"))
      .filter((b) => !b.specialUse || !EXCLUDED_SPECIAL_USE.has(b.specialUse))
      .map((b) => ({
        id: b.name,
        title: mailboxTitle(b),
        enabledByDefault: b.name.toUpperCase() === "INBOX",
      }));
  } finally {
    await host.imap.disconnect(session);
  }
}
