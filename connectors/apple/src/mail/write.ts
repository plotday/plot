import type { CreateLinkDraft, NewContact, NoteWriteBackResult, Thread } from "@plotday/twister";
import type { CreateLinkResult, Note } from "@plotday/twister/plot";
import type { SmtpMessage } from "@plotday/twister/tools/smtp";

import { connectIcloud, resolveThreadMessages, type ResolvedThread } from "./imap-fetch";
import type { MailHost } from "./mail-host";
import {
  accessContactsToRecipients,
  composeRecipients,
  deriveReplyAll,
  isEmpty,
  type OutboundRecipients,
  replySubject,
  splitByRole,
} from "./recipients";
import { sendViaSmtp, sendWithRetry } from "./smtp-send";
import { mailSource, stripAngle } from "./transform";

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

const COMPOSE_DEDUP_WINDOW_MS = 10 * 60 * 1000;

/** Small non-crypto content hash for the compose idempotency key. */
function fnv1aHex(s: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16);
}

/** Build the CreateLinkResult (minus originatingNote) for a sent compose. */
function composeLink(
  host: MailHost,
  draft: CreateLinkDraft,
  subject: string,
  rootId: string
): CreateLinkResult {
  // Built as a standalone variable (not an inline array literal) so its `key`
  // field — valid on NewNote but excluded from the narrower `Omit<NewNote,
  // "thread">` the `notes` field's type collapses to — isn't rejected by
  // TS's excess-property check on a fresh object literal.
  const rootNote = {
    key: rootId,
    content: draft.noteContent ?? "",
    contentType: "markdown" as const,
    authoredBySelf: true,
  };
  return {
    source: mailSource(rootId),
    type: "email",
    title: subject || undefined,
    status: null,
    created: new Date(),
    author: ownerContact(host.appleId),
    meta: {
      syncProvider: APPLE_MAIL,
      syncableId: draft.channelId,
      rootMessageId: rootId,
    },
    notes: [rootNote],
    // channelId omitted → platform auto-fills from draft.channelId.
  };
}

/**
 * Compose write-back: send a brand-new email the user composed in Plot and
 * return a link rooted at the sent Message-ID (so the composed thread becomes
 * the mail thread root, and a Sent-mailbox re-ingest dedups by source). A
 * short content-hash window guards against a re-invoked create double-sending.
 * Delivery failures set `originatingNote.deliveryError` and return no source.
 */
export async function onCreateLinkFn(
  host: MailHost,
  draft: CreateLinkDraft,
  now: Date = new Date()
): Promise<CreateLinkResult | null> {
  if (draft.type !== "email") return null;

  const recipients = composeRecipients(draft.recipients, draft.inviteEmails);
  const subject = draft.title ?? "";
  const body = draft.noteContent ?? "";

  if (isEmpty(recipients)) {
    return {
      originatingNote: {
        deliveryError: { code: "no_recipients", message: "No recipients" },
      },
    };
  }

  // Content-hash dedup: a compose draft has no stable id, so guard against a
  // re-invoked create double-sending within a short window.
  const dedupKey = `compose:${fnv1aHex(
    JSON.stringify([
      subject,
      body,
      recipients.to.map((a) => a.address).sort(),
      recipients.cc.map((a) => a.address).sort(),
      recipients.bcc.map((a) => a.address).sort(),
    ])
  )}`;
  const prior = await host.get<{ rootId: string; at: number }>(dedupKey);
  if (prior && now.getTime() - prior.at < COMPOSE_DEDUP_WINDOW_MS) {
    return {
      ...composeLink(host, draft, subject, prior.rootId),
      originatingNote: { key: prior.rootId, deliveryError: null },
    };
  }

  const message: SmtpMessage = {
    from: { address: host.appleId },
    to: recipients.to,
    cc: recipients.cc.length ? recipients.cc : undefined,
    bcc: recipients.bcc.length ? recipients.bcc : undefined,
    subject,
    text: body,
  };
  const outcome = await sendWithRetry(() =>
    sendViaSmtp(host.smtp, host.appleId, host.appPassword, message)
  );
  if (!outcome.ok) {
    // Preserve the composed content in Plot; surface the failure on its note.
    return {
      originatingNote: {
        deliveryError: { code: outcome.error.code, message: outcome.error.message },
      },
    };
  }

  const rootId = stripAngle(outcome.result.messageId);
  await host.set(dedupKey, { rootId, at: now.getTime() });
  return {
    ...composeLink(host, draft, subject, rootId),
    originatingNote: { key: rootId, deliveryError: null },
  };
}
