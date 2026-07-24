// `ResolvedRecipient` is re-exported from both connector.ts and plot.ts, so it
// is ambiguous under the root's `export *` and does NOT resolve from
// "@plotday/twister" — import entity types from "@plotday/twister/plot".
import type { ResolvedRecipient } from "@plotday/twister/plot";
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

export function isEmpty(r: OutboundRecipients): boolean {
  return r.to.length === 0 && r.cc.length === 0 && r.bcc.length === 0;
}
