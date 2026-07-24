import type { ImapMessage, ImapSession } from "@plotday/twister/tools/imap";

import { isCalendarAttachment } from "./calendar-bundle";
import { connectIcloud } from "./imap-fetch";
import type { MailHost } from "./mail-host";

/**
 * Opaque ref for an inbound mail attachment: `<mailbox>:<uid>:<partNumber>`.
 * `mailbox` is URI-component-encoded so a mailbox name containing ":" can't
 * corrupt the split, and IMAP part numbers ("2", "2.1") never contain ":".
 *
 * Deliberately omits UIDVALIDITY. `MailSyncState.boxes` (see mail-host.ts)
 * now persists a per-mailbox `MailboxCursor` — including a UIDVALIDITY — for
 * every enabled folder, and even for Sent (though Sent's `lastUid` goes
 * unused there). But a ref is resolved independently of that cursor state:
 * this function just SELECTs the ref's own mailbox and fetches by uid+part,
 * with no lookup against the stored cursor for that mailbox. A UIDVALIDITY
 * reset (mailbox recreated/reindexed server-side) therefore still
 * invalidates outstanding refs silently: `fetchAttachment` would address a
 * different (or missing) message and either return wrong bytes or throw a
 * not-found error from the IMAP tool. This is scoped to on-demand
 * attachment re-fetches — not sync correctness — and is an accepted
 * limitation until per-ref UIDVALIDITY validation is worth the added
 * bookkeeping.
 */
export function buildAttachmentRef(
  mailbox: string,
  uid: number,
  partNumber: string
): string {
  return `${encodeURIComponent(mailbox)}:${uid}:${partNumber}`;
}

export type ParsedAttachmentRef = {
  mailbox: string;
  uid: number;
  partNumber: string;
};

/** Inverse of {@link buildAttachmentRef}. Throws on a malformed ref. */
export function parseAttachmentRef(ref: string): ParsedAttachmentRef {
  const parts = ref.split(":");
  if (parts.length !== 3) {
    throw new Error(`Invalid Apple Mail attachment ref: ${ref}`);
  }
  const [mailboxEncoded, uidStr, partNumber] = parts;
  const uid = Number(uidStr);
  if (!mailboxEncoded || !Number.isFinite(uid) || uid <= 0 || !partNumber) {
    throw new Error(`Invalid Apple Mail attachment ref: ${ref}`);
  }
  return { mailbox: decodeURIComponent(mailboxEncoded), uid, partNumber };
}

/**
 * Resolves an inbound `fileRef` ref emitted by transform.ts: opens an IMAP
 * session, SELECTs the encoded mailbox, and fetches the part's decoded
 * bytes. The authoritative mimeType/fileName already live on the stored
 * fileRef action, so — mirroring the Gmail connector's
 * `downloadAttachmentFn` — we return a generic body mimeType here; the
 * runtime uses the action's mimeType for the response's Content-Type.
 *
 * A malformed ref or a stale/missing mailbox+uid+part (e.g. after a
 * UIDVALIDITY reset, see {@link buildAttachmentRef}) throws — this is an
 * expected, user-visible "attachment unavailable" failure, not something to
 * report to error tracking.
 */
export async function downloadAttachmentFn(
  host: MailHost,
  ref: string
): Promise<{ body: Uint8Array; mimeType: string }> {
  const { mailbox, uid, partNumber } = parseAttachmentRef(ref);
  const session = await connectIcloud(host);
  try {
    await host.imap.selectMailbox(session, mailbox);
    const body = await host.imap.fetchAttachment(session, uid, partNumber);
    return { body, mimeType: "application/octet-stream" };
  } finally {
    await host.imap.disconnect(session);
  }
}

/**
 * Reads every referenced file's bytes via the Files tool, for outbound
 * `SmtpMessage.attachments`. A read failure for one file is logged and
 * skipped rather than aborting the whole send (mirrors the Gmail
 * connector's onNoteCreated attachment loop) — an unexpected failure here
 * (a file that should exist but can't be read) is still worth surfacing in
 * logs even though the send itself proceeds without it.
 */
export async function collectFileAttachments(
  host: MailHost,
  fileIds: string[]
): Promise<{ fileName: string; mimeType: string; data: Uint8Array }[]> {
  const attachments: { fileName: string; mimeType: string; data: Uint8Array }[] =
    [];
  for (const fileId of fileIds) {
    try {
      const file = await host.files.read(fileId);
      attachments.push({
        fileName: file.fileName,
        mimeType: file.mimeType,
        data: file.data,
      });
    } catch (err) {
      console.error(
        `[apple-mail] failed to read attachment file ${fileId}:`,
        err
      );
    }
  }
  return attachments;
}

/**
 * Re-downloads a forward's source message's attachment bytes so they can be
 * re-attached to the outbound forward — iCloud IMAP has no server-side
 * "forward with attachments" operation, so the connector must fetch and
 * resend the bytes itself. Best-effort per part: a single failed fetch is
 * logged and skipped rather than failing the whole forward. `mailbox` must
 * already be resolved by the caller (e.g. from `fetchOriginalMessage`);
 * SELECTing it here is idempotent if it's already the selected mailbox.
 *
 * Skips an inline calendar part (text/calendar, application/ics) whose
 * `fileName` is IMAP-parse's synthesized placeholder `"attachment"` — same
 * rationale as `transform.ts`'s `attachmentActions` (see its doc): re-
 * attaching it to a forward would produce a meaningless, extensionless
 * "attachment" file. A genuinely named calendar attachment (e.g.
 * `invite.ics`) is still re-attached normally.
 */
export async function fetchOriginalAttachments(
  host: MailHost,
  session: ImapSession,
  mailbox: string,
  message: ImapMessage
): Promise<{ fileName: string; mimeType: string; data: Uint8Array }[]> {
  await host.imap.selectMailbox(session, mailbox);
  const attachments: { fileName: string; mimeType: string; data: Uint8Array }[] = [];
  for (const part of message.attachments ?? []) {
    if (isCalendarAttachment(part.mimeType) && part.fileName === "attachment") continue;
    try {
      const data = await host.imap.fetchAttachment(session, message.uid, part.partNumber);
      attachments.push({ fileName: part.fileName, mimeType: part.mimeType, data });
    } catch (err) {
      console.error(
        `[apple-mail] forward: failed to fetch attachment ${part.partNumber} on message ${message.uid}:`,
        err
      );
    }
  }
  return attachments;
}
