/**
 * Returns false when an email address almost certainly does not represent a
 * human the user would want to invite, @mention, or assign to a thread
 * (e.g. `no-reply@github.com`, `mailer-daemon@example.com`).
 *
 * Null / empty input returns true — we can't classify it, and a picker
 * showing a contact with no email is better than silently hiding it.
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
  if (atIndex <= 0 || atIndex === lower.length - 1) return true;

  const local = lower.slice(0, atIndex);
  const domain = lower.slice(atIndex + 1);

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
]);

const LOCAL_PREFIXES = [
  "noreply-",
  "no-reply-",
  "donotreply-",
  "notification-",
  "notifications-",
  "reply+",
];

// Word-bounded matches inside the local part. `-` is treated as a word
// boundary so `team-noreply` matches but `nonoreplyable` does not.
const LOCAL_WORD_CONTAINS = [
  /(^|-)(noreply|no-reply|donotreply)(-|$)/,
];

const DOMAIN_LABELS = new Set(["bounces", "bounce", "mailer"]);
