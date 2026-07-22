// `ResolvedRecipient` is re-exported from both connector.ts and plot.ts, so it
// is ambiguous under the root's `export *` and does NOT resolve from
// "@plotday/twister" — import entity types from "@plotday/twister/plot".
import type { Contact, ResolvedRecipient } from "@plotday/twister/plot";
import type { ImapAddress, ImapMessage } from "@plotday/twister/tools/imap";
import type { SmtpAddress } from "@plotday/twister/tools/smtp";

export type OutboundRecipients = {
  to: SmtpAddress[];
  cc: SmtpAddress[];
  bcc: SmtpAddress[];
};

const norm = (email: string) => email.trim().toLowerCase();

/** Strip a leading run of Re:/Fwd:/Fw: prefixes (case-insensitive) and trim. */
export function baseSubject(subject: string | undefined | null): string {
  let s = (subject ?? "").trim();
  const prefix = /^(re|fwd|fw)(\[\d+\])?:\s*/i;
  while (prefix.test(s)) s = s.replace(prefix, "").trim();
  return s;
}

/** Reply subject: "Re: <base>" unless the subject is already an Re:. */
export function replySubject(subject: string | undefined | null): string {
  const base = baseSubject(subject);
  return base ? `Re: ${base}` : "Re:";
}

/**
 * Split a pre-resolved recipient set (curated compose/reply list) into
 * To/Cc/Bcc by thread role. `externalAccountId` is the email address for
 * "addresses" link types. Case-insensitive dedup across all buckets.
 */
export function splitByRole(recipients: ResolvedRecipient[]): OutboundRecipients {
  const out: OutboundRecipients = { to: [], cc: [], bcc: [] };
  const seen = new Set<string>();
  for (const r of recipients) {
    const address = r.externalAccountId?.trim();
    if (!address) continue;
    const key = norm(address);
    if (seen.has(key)) continue;
    seen.add(key);
    const addr: SmtpAddress = r.name ? { address, name: r.name } : { address };
    if (r.role === "bcc") out.bcc.push(addr);
    else if (r.role === "cc") out.cc.push(addr);
    else out.to.push(addr);
  }
  return out;
}

/** Merge curated recipients with free-form typed addresses (as To) for compose. */
export function composeRecipients(
  recipients: ResolvedRecipient[] | undefined,
  inviteEmails: string[] | undefined
): OutboundRecipients {
  const out = splitByRole(recipients ?? []);
  const seen = new Set<string>(
    [...out.to, ...out.cc, ...out.bcc].map((a) => norm(a.address))
  );
  for (const raw of inviteEmails ?? []) {
    const address = raw.trim();
    if (!address) continue;
    const key = norm(address);
    if (seen.has(key)) continue;
    seen.add(key);
    out.to.push({ address });
  }
  return out;
}

/**
 * Reply-all-minus-self from a message's headers: To = From ∪ To, Cc = Cc, with
 * the owner's own identities removed and cross-bucket dedup (a Cc already a To
 * candidate stays in To).
 */
export function deriveReplyAll(
  latest: Pick<ImapMessage, "from" | "to" | "cc">,
  selfEmails: Set<string>
): OutboundRecipients {
  const out: OutboundRecipients = { to: [], cc: [], bcc: [] };
  const seen = new Set<string>([...selfEmails].map(norm));
  const push = (bucket: SmtpAddress[], a: ImapAddress) => {
    const address = a.address?.trim();
    if (!address) return;
    const key = norm(address);
    if (seen.has(key)) return;
    seen.add(key);
    bucket.push(a.name ? { address, name: a.name } : { address });
  };
  for (const a of [...(latest.from ?? []), ...(latest.to ?? [])]) push(out.to, a);
  for (const a of latest.cc ?? []) push(out.cc, a);
  return out;
}

/** Last-resort reply recipients from the thread's access contacts (all To). */
export function accessContactsToRecipients(
  contacts: Contact[] | undefined,
  selfEmails: Set<string>
): OutboundRecipients {
  const out: OutboundRecipients = { to: [], cc: [], bcc: [] };
  const seen = new Set<string>([...selfEmails].map(norm));
  for (const c of contacts ?? []) {
    if (!c.email) continue;
    const key = norm(c.email);
    if (seen.has(key)) continue;
    seen.add(key);
    out.to.push(c.name ? { address: c.email, name: c.name } : { address: c.email });
  }
  return out;
}

export function isEmpty(r: OutboundRecipients): boolean {
  return r.to.length === 0 && r.cc.length === 0 && r.bcc.length === 0;
}
