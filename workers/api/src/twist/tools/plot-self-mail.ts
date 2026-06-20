import type { NewActor, NewLinkWithNotes } from "@plotday/twister/plot";

/**
 * Plot's own transactional sending domains.
 *
 * Plot mails users from this dedicated subdomain (sign-in notices, digests,
 * invitations — `info@`/`noreply@updates.plot.day`). When a user connects the
 * same mailbox those messages sync straight back in, so Plot ingests its own
 * outbound mail as threads ("New sign-in to your Plot account" et al.) and even
 * notifies about it. Dropping inbound mail FROM these domains at the platform
 * ingestion point breaks that loop for every email connector.
 *
 * IMPORTANT: this is the SENDING subdomain only — NOT `plot.day`. Real users
 * and the team live at `@plot.day` (e.g. `kris@plot.day`, the `team@plot.day`
 * reply-to) and their mail must always sync.
 */
export const PLOT_SENDING_DOMAINS: readonly string[] = ["updates.plot.day"];

/** Email of a NewActor, or null when it's an existing-actor reference (id only). */
function actorEmail(actor: NewActor | null | undefined): string | null {
  // NewActor is `{ id } | NewContact`; only NewContact carries an email.
  if (actor && typeof actor === "object" && "email" in actor && typeof actor.email === "string") {
    return actor.email;
  }
  return null;
}

/**
 * The sender (From) email of an inbound link: the link's author, falling back
 * to the first note's author (how email connectors carry the From). Null when
 * no email-bearing author is present.
 */
export function linkSenderEmail(link: NewLinkWithNotes): string | null {
  return actorEmail(link.author) ?? actorEmail(link.notes?.[0]?.author) ?? null;
}

/**
 * True when this inbound link is one of Plot's own transactional emails looping
 * back through a connected mailbox — i.e. its sender is on a Plot sending
 * domain (see {@link PLOT_SENDING_DOMAINS}). Platform-level and provider-
 * agnostic: keyed on the sender domain (exclusive to Plot's outbound mail), so
 * it applies to Gmail, Outlook, IMAP, and any future email connector without
 * per-connector code.
 */
export function isPlotSelfMail(link: NewLinkWithNotes): boolean {
  const email = linkSenderEmail(link);
  if (!email) return false;
  const at = email.lastIndexOf("@");
  if (at < 0) return false;
  const domain = email.slice(at + 1).toLowerCase();
  return PLOT_SENDING_DOMAINS.includes(domain);
}
