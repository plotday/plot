/**
 * Raw, normalized signals a connector extracts from a source item. Connectors
 * emit these; the platform derives classification from them.
 *
 * This is the inverse of `./facets`: facets are a *verdict* (a connector's
 * conclusion), signals are *evidence* (what the connector observed). Emitting
 * signals lets the platform re-derive classification without a connector
 * redeploy, and lets it combine connector observations with recipient-relative
 * facts a connector cannot see (does this user know this sender?).
 *
 * Every field is nullable — populate only what the source actually provides.
 *
 * Deliberately absent: a body-length field. The platform already holds the
 * note content, so it derives body length itself instead of trusting a
 * number connectors would each have to compute independently — and,
 * historically, got wrong: connectors used to report the raw content
 * string's length, which is markup length whenever the note is HTML.
 */

/** Header and metadata signals from an email message. */
export type MailSignals = {
  /** List-Id header value, verbatim, or null. */
  listId: string | null;
  /** List-Unsubscribe header value, verbatim, or null. */
  listUnsubscribe: string | null;
  /** Precedence header ("bulk", "list", "junk", "auto_reply"), or null. */
  precedence: string | null;
  /** Auto-Submitted header ("auto-generated", "no", …), or null. */
  autoSubmitted: string | null;
  /** Return-Path header. "<>" or "" indicates a bounce/automated sender. */
  returnPath: string | null;
  /** Importance or X-Priority header, or the provider's equivalent. */
  importance: string | null;
  /** Sender address, lowercased, or null. */
  fromAddress: string | null;
  /** Sender display name, or null. */
  fromName: string | null;
  /** Number of To recipients. `1` means the user was the sole direct recipient. */
  toCount: number | null;
  /** Number of Cc recipients. */
  ccCount: number | null;
  /** True when In-Reply-To or References was present. */
  isReply: boolean | null;
  /** Subject line, or null. */
  subject: string | null;
  /**
   * The Authentication-Results header carrying the receiving MTA's own verdict.
   * The CONNECTOR selects which header to trust (only it knows its provider's
   * authserv-id); the platform parses the value. Null when absent or untrusted.
   */
  authResults: string | null;
  /**
   * Provider content categories, verbatim. Gmail's CATEGORY_PROMOTIONS /
   * CATEGORY_UPDATES / CATEGORY_SOCIAL / CATEGORY_FORUMS / CATEGORY_PERSONAL,
   * or another provider's equivalent bucket.
   */
  providerCategories: string[];
  /** Provider user-state flags, verbatim: IMPORTANT, STARRED, FLAGGED, … */
  providerFlags: string[];
};

/** Signals a connector attaches to a `NewLink`. */
export type LinkSignals = {
  mail?: MailSignals;
  /**
   * The `key` of the note these signals were read from — the message the
   * connector picked as the conversation's classification parent (normally
   * the originating message).
   *
   * A conversation link carries one note per message, and body-derived
   * classification (how long the message really is, what it links to) must
   * read the SAME message the headers came from. Without this pointer the
   * platform can only use the link's first note, which on an incremental
   * sync is often a later reply — so a thread's classification would churn
   * every time someone replies to it.
   *
   * Set it to the `key` of the note built from that message, using the same
   * expression the note itself was keyed with. Omit it when the link has a
   * single note, or when its notes are unkeyed; the platform then falls back
   * to the first note. When the key matches no note in the link, the
   * platform classifies from `link.preview` instead.
   */
  noteKey?: string | null;
};

const NOREPLY_LOCALPART =
  /^(no-?reply|do-?not-?reply|donotreply|notifications?|notify|mailer-daemon|bounce|postmaster|automated|auto|alerts?|updates?)\b/;

function localPart(address: string | null): string {
  if (!address) return "";
  const at = address.indexOf("@");
  return (at === -1 ? address : address.slice(0, at)).toLowerCase();
}

/**
 * True when an address's local part marks it as an automated / no-reply /
 * notification sender (no-reply@, notify@, notifications@, alerts@, …). This is
 * the identity-trust signal used to enable name-conflict detection for shared
 * sender addresses; it deliberately ignores list/precedence headers (those are
 * per-message automation signals, not shared-identity signals).
 */
export function isNoReplySender(address: string | null): boolean {
  return NOREPLY_LOCALPART.test(localPart(address));
}
