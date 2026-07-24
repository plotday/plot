import type { Channel, LinkTypeConfig } from "@plotday/twister/tools/integrations";
import type { ImapMailbox } from "@plotday/twister/tools/imap";

import { connectIcloud, isSentMailbox } from "./imap-fetch";
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
 * Special-use attributes excluded from channel enumeration. Sent is NOT
 * listed here — it is excluded via `isSentMailbox` below instead, the same
 * predicate `resolveSentMailbox` (`imap-fetch.ts`) uses to find the mailbox
 * sync reads Sent messages from, so the two can never disagree about which
 * mailbox is Sent (see `isSentMailbox`'s docstring). A specialUse-only check
 * here would miss a server that doesn't advertise SPECIAL-USE and only
 * exposes Sent as a plainly-named "Sent Messages" folder — that folder would
 * be offered as an enable-able channel while sync separately reads it as
 * Sent, double-ingesting its mail. Drafts, Trash, and Junk have no sync
 * value and have no such name-based counterpart to keep in sync with, so
 * they stay a simple specialUse set. Archive, All, and Flagged are
 * deliberately NOT excluded — an Archive mailbox (or similar) is the whole
 * point of this feature.
 */
const EXCLUDED_SPECIAL_USE = new Set(["\\Drafts", "\\Trash", "\\Junk"]);

/** Render a mailbox's hierarchical `name` as a human-readable path, e.g. "Archive / 2024". */
function mailboxTitle(box: ImapMailbox): string {
  if (box.name.toUpperCase() === "INBOX") return "Inbox";
  return box.name.split(box.delimiter || "/").join(" / ");
}

/**
 * Every selectable IMAP mailbox becomes its own channel, except Sent. INBOX
 * is the only one enabled by default; the rest are opt-in. Sent is excluded
 * by `isSentMailbox` (`imap-fetch.ts`) — the same predicate
 * `resolveSentMailbox` uses to find the mailbox sync reads Sent messages
 * from — so channel enumeration and Sent resolution can never disagree
 * about which mailbox is Sent, even on a server that omits SPECIAL-USE and
 * only exposes a plainly-named "Sent Messages" folder. Drafts, Trash, and
 * Junk have no sync value and are excluded by specialUse alone.
 */
export async function getMailChannels(host: MailHost): Promise<Channel[]> {
  const session = await connectIcloud(host);
  try {
    const boxes = await host.imap.listMailboxes(session);
    return boxes
      .filter((b) => !b.flags.includes("\\Noselect"))
      .filter((b) => !isSentMailbox(b))
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
