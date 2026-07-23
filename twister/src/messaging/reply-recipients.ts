import type { ResolvedRecipient } from "../plot";

/** A resolved outbound recipient: address plus optional display name. */
export type Addressee = { address: string; name: string | null };

/**
 * Outbound recipient lists for a reply, split by header role. `bcc` recipients
 * MUST be addressed privately (a separate Bcc header / bccRecipients field) so
 * they are never exposed to the To/Cc recipients.
 */
export type ReplyRecipients = {
  to: Addressee[];
  cc: Addressee[];
  bcc: Addressee[];
  /**
   * True when the note carried an explicit, user-curated recipient set (either
   * platform-resolved `recipients` or a connector-resolved access-contact
   * constraint). When true and every list is empty, the connector should
   * surface a `deliveryError` ("no deliverable recipients") rather than
   * silently skipping — the user asked to send to specific people and none
   * could be addressed. When false (a plain reply-all), an empty result just
   * means the conversation had no other participants.
   */
  curated: boolean;
};

type Role = "to" | "cc" | "bcc";

function roleOf(role: string | null | undefined, fallback: Role): Role {
  return role === "cc" || role === "bcc" || role === "to" ? role : fallback;
}

/** Case-insensitive de-dupe preserving first-seen order, keyed on address. */
function dedupe(addressees: Addressee[]): Addressee[] {
  const seen = new Set<string>();
  const out: Addressee[] = [];
  for (const a of addressees) {
    const key = a.address.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(a);
  }
  return out;
}

/**
 * Compute the To/Cc/Bcc lists for an outbound reply, shared by every
 * `sharingModel: "message"` (email-style) connector so recipient resolution
 * lives in ONE tested place instead of being re-implemented — and
 * re-misimplemented — per connector.
 *
 * Three cases, in priority order:
 *
 * 1. **Platform-resolved recipients** (`recipients` non-null): the note carried
 *    a curated recipient set and the runtime resolved it to addresses + roles,
 *    with the acting user's own identities already removed. Authoritative. This
 *    is the only case that can carry a display `name` — it comes from the
 *    resolved contact — so connectors relying on the other cases get `name: null`.
 * 2. **Access-contact fallback** (`recipients` null, `accessContactEmails`
 *    non-null): header participants are narrowed to that set; curated addresses
 *    not on the message are folded into `To`. Self is excluded via `selfEmails`.
 * 3. **Reply-all** (`recipients` null, `accessContactEmails` null): reply to the
 *    original participants (From ∪ To → To, Cc → Cc), minus self.
 *
 * **Self-reply fallback:** a self-email thread — a message you sent to your own
 * or another linked address — otherwise resolves to no recipients, because
 * every original participant is you and each case above removes self. When the
 * result is empty AND the original message had no non-self To/Cc participant
 * (i.e. this is a genuine self-thread, not a mixed thread narrowed to self) AND
 * every original sender is self, the reply is addressed back to the original
 * sender (`headerFrom`) so it stays deliverable. The connector still sends as
 * its own mailbox — for the copy you received in, that mailbox is the original
 * recipient.
 *
 * @param recipients platform-resolved curated recipients (`note.recipients`), or null
 * @param accessContactEmails note access list resolved to lowercased emails, or null (fallback only)
 * @param headerTo original message From ∪ To addresses (any case); may include self, which the header-driven cases exclude
 * @param headerCc original message Cc addresses (any case); may include self, which the header-driven cases exclude
 * @param selfEmails the acting user's own addresses (lowercased) — excluded in the header-driven cases
 * @param headerFrom original message From address(es) (any case), NOT self-filtered — drives the self-reply fallback
 * @param defaultRole role for recipients whose `role` is null (defaults to `"to"`)
 */
export function resolveOutboundReplyRecipients(args: {
  recipients: ResolvedRecipient[] | null;
  accessContactEmails: Set<string> | null;
  headerTo: string[];
  headerCc: string[];
  selfEmails: Set<string>;
  headerFrom?: string[];
  defaultRole?: Role;
}): ReplyRecipients {
  const {
    recipients,
    accessContactEmails,
    headerTo,
    headerCc,
    selfEmails,
    headerFrom = [],
    defaultRole = "to",
  } = args;

  const base = resolveBase();

  // Self-reply fallback: a self-email thread — a message you sent to your own
  // or another linked address — otherwise resolves to no recipients, because
  // every original participant is you and each case above removes self. When
  // the result is empty AND the original message had no non-self To/Cc
  // participant (i.e. a genuine self-thread, not a mixed thread the user
  // narrowed to themselves) AND every original sender is self, address the
  // reply back to the original sender (`headerFrom`) so it stays deliverable.
  // The connector still sends as its own mailbox — for the copy you received
  // in, that mailbox is the original recipient. Self is judged by `selfEmails`
  // here (not by assuming the connector pre-filtered the headers), so this
  // works whether or not a given connector strips self before calling.
  const isSelf = (email: string) => selfEmails.has(email.toLowerCase());
  const hasNonSelfHeaderParticipant =
    headerTo.some((email) => !isSelf(email)) ||
    headerCc.some((email) => !isSelf(email));
  if (
    base.to.length === 0 &&
    base.cc.length === 0 &&
    base.bcc.length === 0 &&
    !hasNonSelfHeaderParticipant &&
    headerFrom.length > 0 &&
    headerFrom.every(isSelf)
  ) {
    const fallbackTo: Addressee[] = headerFrom.map((address) => ({
      address,
      name: null,
    }));
    return splitPrecedence(dedupe(fallbackTo), [], [], base.curated);
  }

  return base;

  function resolveBase(): ReplyRecipients {
    // Case 1: platform-resolved curated recipients (authoritative). Names come
    // from the platform-resolved contact, so they're carried through.
    if (recipients !== null) {
      const to: Addressee[] = [];
      const cc: Addressee[] = [];
      const bcc: Addressee[] = [];
      for (const r of recipients) {
        if (!r.externalAccountId) continue;
        const bucket = roleOf(r.role, defaultRole);
        const addressee: Addressee = { address: r.externalAccountId, name: r.name };
        (bucket === "bcc" ? bcc : bucket === "cc" ? cc : to).push(addressee);
      }
      return splitPrecedence(to, cc, bcc, true);
    }

    // Case 2: access-contact constraint resolved by the connector (fallback).
    // Addresses come from message headers, which carry no display name.
    if (accessContactEmails !== null) {
      const allow = (email: string) =>
        !selfEmails.has(email.toLowerCase()) &&
        accessContactEmails.has(email.toLowerCase());
      const to: Addressee[] = headerTo
        .filter(allow)
        .map((address) => ({ address, name: null }));
      const cc: Addressee[] = headerCc
        .filter(allow)
        .map((address) => ({ address, name: null }));
      // Fold in curated addresses that weren't on the original message.
      const headerEmails = new Set(
        [...headerTo, ...headerCc].map((e) => e.toLowerCase())
      );
      const already = new Set(
        [...to, ...cc].map((a) => a.address.toLowerCase())
      );
      for (const email of accessContactEmails) {
        if (selfEmails.has(email)) continue;
        if (headerEmails.has(email)) continue;
        if (already.has(email)) continue;
        to.push({ address: email, name: null });
      }
      return splitPrecedence(to, cc, [], true);
    }

    // Case 3: reply-all — every original participant except self. Addresses
    // come from message headers, which carry no display name.
    const notSelf = (email: string) => !selfEmails.has(email.toLowerCase());
    return splitPrecedence(
      headerTo.filter(notSelf).map((address) => ({ address, name: null })),
      headerCc.filter(notSelf).map((address) => ({ address, name: null })),
      [],
      false
    );
  }
}

/**
 * De-dupe each list and enforce role precedence bcc > cc > to, so an address
 * that appears in more than one bucket lands only in the most private one and
 * never leaks (a Bcc address must not also sit in To/Cc).
 */
function splitPrecedence(
  to: Addressee[],
  cc: Addressee[],
  bcc: Addressee[],
  curated: boolean
): ReplyRecipients {
  const bccSet = new Set(bcc.map((a) => a.address.toLowerCase()));
  const ccSet = new Set(cc.map((a) => a.address.toLowerCase()));
  return {
    to: dedupe(to).filter(
      (a) => !bccSet.has(a.address.toLowerCase()) && !ccSet.has(a.address.toLowerCase())
    ),
    cc: dedupe(cc).filter((a) => !bccSet.has(a.address.toLowerCase())),
    bcc: dedupe(bcc),
    curated,
  };
}
