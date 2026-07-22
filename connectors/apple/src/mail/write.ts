import type { NewContact, NoteWriteBackResult, Thread } from "@plotday/twister";
import type { Note } from "@plotday/twister/plot";
import type { SmtpMessage } from "@plotday/twister/tools/smtp";

import { connectIcloud, resolveThreadMessages, type ResolvedThread } from "./imap-fetch";
import type { MailHost } from "./mail-host";
import {
  accessContactsToRecipients,
  deriveReplyAll,
  isEmpty,
  type OutboundRecipients,
  replySubject,
  splitByRole,
} from "./recipients";
import { sendViaSmtp, sendWithRetry } from "./smtp-send";
import { stripAngle } from "./transform";

/** syncProvider tag for this connector's mail links (distinct from calendar "apple"). */
export const APPLE_MAIL = "apple-mail";

/** The connection owner as a contact (for owner-authored links). */
export function ownerContact(appleId: string): NewContact {
  return { email: appleId, name: "" };
}

/** Angle-wrap a stripped Message-ID for an RFC header. */
export function angle(id: string): string {
  return id.startsWith("<") ? id : `<${id}>`;
}

/** Read `thread.meta.rootMessageId` iff this is one of our mail threads. */
export function mailRootId(thread: Thread): string | null {
  const meta = thread.meta ?? {};
  if (meta.syncProvider !== APPLE_MAIL) return null;
  const rootId = meta.rootMessageId;
  return typeof rootId === "string" && rootId.length > 0 ? rootId : null;
}

/**
 * Reply write-back. Resolves the thread's latest INBOX message (best-effort,
 * for threading headers + reply-all recipients), sends via SMTP, and returns a
 * NoteWriteBackResult. Delivery failures return a `deliveryError` rather than
 * throwing. The reply note's key is set to the sent Message-ID so a Sent-mailbox
 * re-ingest upserts onto the same note (echo suppression by key idempotency).
 */
export async function onNoteCreatedFn(
  host: MailHost,
  note: Note,
  thread: Thread
): Promise<NoteWriteBackResult | void> {
  const rootId = mailRootId(thread);
  if (!rootId) return; // not one of our mail threads

  const selfEmails = new Set<string>([host.appleId.toLowerCase()]);

  // Best-effort: resolve the thread's latest INBOX message for threading
  // headers + reply-all recipients.
  const session = await connectIcloud(host);
  let resolved: ResolvedThread;
  try {
    resolved = await resolveThreadMessages(host, session, rootId, thread.title);
  } finally {
    await host.imap.disconnect(session);
  }
  const latest = resolved.latest;

  // Recipients: curated set wins; else reply-all from the latest message; else
  // the thread's access contacts; else give up with a delivery error.
  let recipients: OutboundRecipients;
  if (note.recipients != null) {
    recipients = splitByRole(note.recipients);
  } else if (latest) {
    recipients = deriveReplyAll(latest, selfEmails);
  } else {
    recipients = accessContactsToRecipients(thread.accessContacts, selfEmails);
  }
  if (isEmpty(recipients)) {
    return { deliveryError: { code: "no_recipients", message: "No one to reply to" } };
  }

  const inReplyTo = latest?.messageId ?? angle(rootId);
  const references = latest
    ? [...(latest.references ?? []), latest.messageId ?? angle(rootId)]
    : [angle(rootId)];

  const message: SmtpMessage = {
    from: { address: host.appleId },
    to: recipients.to,
    cc: recipients.cc.length ? recipients.cc : undefined,
    bcc: recipients.bcc.length ? recipients.bcc : undefined,
    subject: replySubject(thread.title ?? latest?.subject),
    text: note.content ?? "",
    inReplyTo,
    references,
  };

  const outcome = await sendWithRetry(() =>
    sendViaSmtp(host.smtp, host.appleId, host.appPassword, message)
  );
  if (!outcome.ok) {
    return { deliveryError: { code: outcome.error.code, message: outcome.error.message } };
  }
  return { key: stripAngle(outcome.result.messageId), deliveryError: null };
}
