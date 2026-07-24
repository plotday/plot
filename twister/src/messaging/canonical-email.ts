/**
 * Gmail-scoped address canonicalization.
 *
 * Google documents that `gmail.com` / `googlemail.com` ignore dots in the local
 * part and everything from the first `+` onward, so `k.b@gmail.com`,
 * `kb@gmail.com`, and `k.b+news@gmail.com` all deliver to one mailbox. Message
 * headers, however, preserve whichever variant was used, so a literal string
 * comparison treats them as different people.
 *
 * NO other domain is normalized beyond lowercasing. `+` is legal in a local
 * part and sub-addressing is not universal, so collapsing `finance+ap@acme.com`
 * into `finance@acme.com` could merge two genuinely distinct mailboxes — and
 * merging contacts merges thread visibility, which makes a wrong merge a
 * privacy bug rather than a cosmetic one.
 */
const GMAIL_DOMAINS = new Set(["gmail.com", "googlemail.com"]);

function split(email: string): { local: string; domain: string } | null {
  const lower = email.trim().toLowerCase();
  const at = lower.lastIndexOf("@");
  if (at <= 0 || at === lower.length - 1) return null;
  return { local: lower.slice(0, at), domain: lower.slice(at + 1) };
}

/**
 * ROW identity: lowercase, and for Gmail strip dots from the local part. The
 * `+tag` is DELIBERATELY preserved — tagged addresses stay their own contact so
 * they remain visible and searchable. Use {@link baseEmail} for person identity.
 */
export function canonicalizeEmail(email: string): string {
  const parts = split(email);
  if (!parts) return email.trim().toLowerCase();
  const { local, domain } = parts;
  if (!GMAIL_DOMAINS.has(domain)) return `${local}@${domain}`;
  const stripped = local.replace(/\./g, "");
  if (stripped.length === 0) return `${local}@${domain}`;
  return `${stripped}@gmail.com`;
}

/**
 * PERSON identity: {@link canonicalizeEmail} plus, for Gmail, removal of the
 * `+tag`. Addresses sharing a base belong to one human, so they group in the
 * UI and count as "me" for self-exclusion — but they remain separate rows.
 */
export function baseEmail(email: string): string {
  const parts = split(email);
  if (!parts) return email.trim().toLowerCase();
  const { local, domain } = parts;
  if (!GMAIL_DOMAINS.has(domain)) return `${local}@${domain}`;
  const untagged = local.split("+")[0] ?? "";
  const stripped = untagged.replace(/\./g, "");
  if (stripped.length === 0) return `${local}@${domain}`;
  return `${stripped}@gmail.com`;
}
