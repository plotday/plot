import type { ImapMessage, ImapSession } from "@plotday/twister/tools/imap";

import type { MailHost } from "./mail-host";
import { baseSubject } from "./recipients";
import { rootMessageId } from "./transform";

export const ICLOUD_IMAP = { host: "imap.mail.me.com", port: 993, tls: true } as const;

export async function connectIcloud(host: MailHost): Promise<ImapSession> {
  return host.imap.connect({
    ...ICLOUD_IMAP,
    username: host.appleId,
    password: host.appPassword,
  });
}

/** The account's Sent mailbox name, or null if none is discoverable. */
export async function resolveSentMailbox(
  host: MailHost,
  session: ImapSession
): Promise<string | null> {
  const boxes = await host.imap.listMailboxes(session);
  const bySpecialUse = boxes.find((b) => b.specialUse === "\\Sent");
  if (bySpecialUse) return bySpecialUse.name;
  const byName = boxes.find((b) => /^sent/i.test(b.name));
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
