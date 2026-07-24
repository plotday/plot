import type { ImapMailbox, ImapMessage, ImapSession } from "@plotday/twister/tools/imap";

import type { MailHost } from "./mail-host";
import { baseSubject } from "./recipients";
import { rootMessageId, stripAngle } from "./transform";

export const ICLOUD_IMAP = { host: "imap.mail.me.com", port: 993, tls: true } as const;

export async function connectIcloud(host: MailHost): Promise<ImapSession> {
  return host.imap.connect({
    ...ICLOUD_IMAP,
    username: host.appleId,
    password: host.appPassword,
  });
}

/**
 * Whether `box` is the account's Sent mailbox: declared via IMAP SPECIAL-USE
 * (RFC 6154) when the server advertises it, or — on a server that doesn't —
 * identified by name. This is the single predicate for "is this Sent",
 * shared by `resolveSentMailbox` below (which mailbox sync reads Sent
 * messages from) and `getMailChannels` (`channels.ts`, which mailboxes are
 * offered as enable-able channels). Using one predicate in both places means
 * they can never disagree: a server that omits SPECIAL-USE can't end up
 * offering "Sent Messages" as an enable-able channel while sync separately
 * reads mail from it under the hood.
 *
 * The name fallback matches a closed list of known Sent-mailbox names
 * (case-insensitive, trimmed) rather than a "starts with sent" prefix.
 * Because this same predicate also decides channel *selectability*, a prefix
 * match would silently make any folder whose name merely starts with "sent"
 * (e.g. "Sentiment", "Sent by client") permanently unselectable as a
 * channel, with no error or indication why.
 */
export function isSentMailbox(box: Pick<ImapMailbox, "name" | "specialUse">): boolean {
  if (box.specialUse === "\\Sent") return true;
  const name = box.name.trim().toLowerCase();
  return name === "sent" || name === "sent messages" || name === "sent items" || name === "sent mail";
}

/** The account's Sent mailbox name, or null if none is discoverable. */
export async function resolveSentMailbox(
  host: MailHost,
  session: ImapSession
): Promise<string | null> {
  const boxes = await host.imap.listMailboxes(session);
  // Special-use priority: a genuine `\Sent` box always wins over a mere name
  // match, so a folder like "Sent Archive" can't outrank the real one.
  const bySpecialUse = boxes.find((b) => b.specialUse === "\\Sent");
  if (bySpecialUse) return bySpecialUse.name;
  const byName = boxes.find(isSentMailbox);
  return byName ? byName.name : null;
}

/** Select `mailbox` and fetch the given UIDs (headers + body), chunked by 50. */
export async function fetchUidRange(
  host: MailHost,
  session: ImapSession,
  mailbox: string,
  uids: number[]
): Promise<ImapMessage[]> {
  if (uids.length === 0) return [];
  await host.imap.selectMailbox(session, mailbox);
  const out: ImapMessage[] = [];
  for (let i = 0; i < uids.length; i += 50) {
    const chunk = uids.slice(i, i + 50);
    const msgs = await host.imap.fetchMessages(session, chunk, {
      headers: true,
      body: true,
      bodyType: "both",
    });
    out.push(...msgs);
  }
  return out;
}

/** Bounded look-back for resolving a thread's messages at write-back time. */
const WRITE_BACK_WINDOW_MS = 180 * 24 * 60 * 60 * 1000; // 180 days

export type ResolvedThread = {
  /** The thread's INBOX messages (headers only), oldest→newest. */
  inboxMessages: ImapMessage[];
  /** INBOX UIDs of those messages (for setFlags). */
  inboxUids: number[];
  /** Newest INBOX message, or null when none resolved. */
  latest: ImapMessage | null;
};

/** Fetch headers-only for `uids` in the selected mailbox, chunked by 50. */
export async function fetchHeaders(
  host: MailHost,
  session: ImapSession,
  uids: number[]
): Promise<ImapMessage[]> {
  if (uids.length === 0) return [];
  const out: ImapMessage[] = [];
  for (let i = 0; i < uids.length; i += 50) {
    const chunk = uids.slice(i, i + 50);
    const msgs = await host.imap.fetchMessages(session, chunk, {
      headers: true,
      body: false,
    });
    out.push(...msgs);
  }
  return out;
}

/**
 * Resolve the INBOX messages belonging to the Plot thread whose root id is
 * `rootId`, at write-back time. IMAP SEARCH cannot query by References, so we
 * narrow by SUBJECT (a thread's members share a base subject) within a bounded
 * window, fetch headers only, and keep messages whose computed thread root
 * equals `rootId`. Threads older than the window (or whose subject changed)
 * resolve empty; callers then fall back to root-id-only threading / skip
 * flagging.
 */
export async function resolveThreadMessages(
  host: MailHost,
  session: ImapSession,
  rootId: string,
  subject: string | undefined,
  now: Date = new Date()
): Promise<ResolvedThread> {
  await host.imap.selectMailbox(session, "INBOX");
  const since = new Date(now.getTime() - WRITE_BACK_WINDOW_MS);
  const base = baseSubject(subject);
  const uids = await host.imap.search(
    session,
    base ? { subject: base, since } : { since }
  );
  const msgs = await fetchHeaders(host, session, uids);
  const inboxMessages = msgs
    .filter((m) => rootMessageId(m) === rootId)
    .sort((a, b) => (a.date?.getTime() ?? 0) - (b.date?.getTime() ?? 0));
  return {
    inboxMessages,
    inboxUids: inboxMessages.map((m) => m.uid),
    latest: inboxMessages.length > 0 ? inboxMessages[inboxMessages.length - 1] : null,
  };
}

/**
 * Locate a forward's source message by its stripped Message-ID. There is no
 * IMAP "search by Message-ID" (`ImapSearchCriteria` has no such field), so
 * this reuses the exact window-search-then-local-filter technique
 * `resolveThreadMessages` already uses: search a bounded window (base
 * subject + the same `WRITE_BACK_WINDOW_MS` floor), fetch headers only for
 * the candidates, then filter locally by exact Message-ID match. INBOX is
 * tried first, then the Sent mailbox (a forwarded message may be one the
 * owner sent, not just received mail). On a match, the full headers+body
 * are fetched for that one UID via `fetchUidRange`.
 *
 * Accepted v1 limitation: since this reuses the 180-day subject+since
 * window (same as reply threading), a source whose compose subject was
 * fully rewritten, or that is older than 180 days, may not resolve — the
 * caller surfaces a `not_found` delivery error in that case. A persistent
 * uid index was deliberately rejected (uidValidity invalidation + storage
 * growth).
 */
export async function fetchOriginalMessage(
  host: MailHost,
  session: ImapSession,
  forwardKey: string,
  subjectHint: string | undefined,
  now: Date = new Date()
): Promise<{ mailbox: string; message: ImapMessage } | null> {
  const since = new Date(now.getTime() - WRITE_BACK_WINDOW_MS);
  const base = baseSubject(subjectHint);
  const criteria = base ? { subject: base, since } : { since };

  const findUidIn = async (mailbox: string): Promise<number | null> => {
    await host.imap.selectMailbox(session, mailbox);
    const uids = await host.imap.search(session, criteria);
    const candidates = await fetchHeaders(host, session, uids);
    const match = candidates.find((m) => stripAngle(m.messageId ?? "") === forwardKey);
    return match ? match.uid : null;
  };

  const resolve = async (mailbox: string): Promise<{ mailbox: string; message: ImapMessage } | null> => {
    const uid = await findUidIn(mailbox);
    if (uid === null) return null;
    const full = await fetchUidRange(host, session, mailbox, [uid]);
    return full.length > 0 ? { mailbox, message: full[0] } : null;
  };

  const inboxHit = await resolve("INBOX");
  if (inboxHit) return inboxHit;

  const sentMailbox = await resolveSentMailbox(host, session);
  if (sentMailbox) {
    const sentHit = await resolve(sentMailbox);
    if (sentHit) return sentHit;
  }

  return null;
}
