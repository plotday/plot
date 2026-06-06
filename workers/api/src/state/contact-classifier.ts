/**
 * Returns false when an email address almost certainly does not represent a
 * human the user would want to invite, @mention, or assign to a thread
 * (e.g. `no-reply@github.com`, `mailer-daemon@example.com`).
 *
 * Null / empty input returns true — we can't classify it, and a picker
 * showing a contact with no email (e.g. a synced external actor with only
 * an external id) is better than silently hiding it.
 *
 * Non-empty strings that don't look like a valid `local@domain` address
 * return false — they're garbage from malformed header parsing
 * (`undisclosed-recipients:;`, `"bayne` from a bad comma split), and
 * surfacing them as inviteable people is strictly worse than hiding them.
 *
 * This is the going-forward source of truth for the `contact.inviteable`
 * column. The SQL backfill in 20260418050001_add_contact_inviteable.sql
 * uses looser patterns for bulk classification of existing rows.
 *
 * `_name` is accepted but not consulted today — reserved for future signals.
 */
export function classifyInviteable(
  email: string | null,
  _name?: string | null,
): boolean {
  if (!email) return true;

  const lower = email.toLowerCase();
  const atIndex = lower.lastIndexOf("@");
  // Malformed: non-empty string without a proper `local@domain` shape
  // (e.g. `undisclosed-recipients:;`, `"bayne`, a bare domain). These are
  // always garbage — never surface them as inviteable people.
  if (atIndex <= 0 || atIndex === lower.length - 1) return false;

  const rawLocal = lower.slice(0, atIndex);
  const domain = lower.slice(atIndex + 1);

  // Normalize `_` and `.` to `-` so variants like `no_reply`, `no-reply.ontario`,
  // and `testflight_no_reply` collapse to the same shape we already recognize.
  const local = rawLocal.replace(/[_.]/g, "-");

  if (EXACT_LOCAL.has(local)) return false;
  if (LOCAL_PREFIXES.some((p) => local.startsWith(p))) return false;
  if (LOCAL_WORD_CONTAINS.some((re) => re.test(local))) return false;

  const domainLabels = domain.split(".");
  if (domainLabels.some((label) => DOMAIN_LABELS.has(label))) return false;

  return true;
}

const EXACT_LOCAL = new Set([
  "no-reply",
  "noreply",
  "donotreply",
  "do-not-reply",
  "mailer-daemon",
  "postmaster",
  "bounces",
  "bounce",
  "notifications",
  "notification",
  "alerts",
  "alert",
  "auto-confirm",
  "automated",
  "newsletter",
  "newsletters",
  "unsubscribe",
]);

const LOCAL_PREFIXES = [
  "noreply-",
  "no-reply-",
  "donotreply-",
  "notification-",
  "notifications-",
  "reply+",
  "reply-",
  "noreply+",
  "no-reply+",
  "newsletter-",
  "newsletters-",
  "unsubscribe-",
  "unsubscribe+",
];

// Word-bounded matches inside the local part. `-` is treated as a word
// boundary so `team-noreply` matches but `nonoreplyable` does not.
// The trailing `\+` also catches `foo-reply+token@` style Google OAuth
// verification addresses.
const LOCAL_WORD_CONTAINS = [
  /(^|-)(noreply|no-reply|donotreply)(-|$)/,
  /(^|-)reply(-|\+|$)/,
  /(^|-)(newsletter|newsletters|unsubscribe)(-|$)/,
  // Transactional / billing senders: invoice(s), statement(s), receipt(s),
  // billing, payment(s). `+` is treated as a word boundary on both sides so
  // plus-tagged variants like `invoice+statements@`, `invoice+statements+acct_x@`,
  // and `billing+acct_x@` are caught alongside `failed-payments@`.
  /(^|-|\+)(invoices?|statements?|receipts?|billing|payments?)(-|\+|$)/,
];

const DOMAIN_LABELS = new Set([
  "bounces",
  "bounce",
  "mailer",
  "reply",
  "noreply",
  "no-reply",
]);
