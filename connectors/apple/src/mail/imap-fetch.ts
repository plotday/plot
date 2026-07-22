import type { ImapMessage, ImapSession } from "@plotday/twister/tools/imap";

import type { MailHost } from "./mail-host";

const ICLOUD_IMAP = { host: "imap.mail.me.com", port: 993, tls: true } as const;

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
