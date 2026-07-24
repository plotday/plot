import {
  ActionType,
  resolveOutboundReplyRecipients,
  type Action,
  type Actor,
  type Addressee,
  type CreateLinkDraft,
  type NewContact,
  type NoteWriteBackResult,
  type Thread,
} from "@plotday/twister";
import type { CreateLinkResult, Note } from "@plotday/twister/plot";
import type { ImapAddress, ImapMessage } from "@plotday/twister/tools/imap";
import type { SmtpAddress, SmtpMessage } from "@plotday/twister/tools/smtp";

import { parse } from "../product-channel";
import { collectFileAttachments, fetchOriginalAttachments } from "./attachments";
import {
  connectIcloud,
  fetchOriginalMessage,
  resolveThreadMessages,
  type ResolvedThread,
} from "./imap-fetch";
import type { MailHost } from "./mail-host";
import {
  composeRecipients,
  isEmpty,
  type OutboundRecipients,
  replySubject,
} from "./recipients";
import { sendViaSmtp, sendWithRetry } from "./smtp-send";
import { bodyOf, mailSource, stripAngle } from "./transform";

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
 * The raw IMAP mailbox a thread's messages live in, read from
 * `thread.meta.channelId` (the platform populates it from the link's persisted
 * top-level channelId — see transform.ts). `channelId` is namespaced
 * ("mail:<rawId>"); `parse` splits on the FIRST ':' so a mailbox name
 * containing '/' or ':' round-trips unchanged. Falls back to "INBOX" for
 * threads synced before multi-folder existed, whose links predate any other
 * value.
 */
export function mailChannelRawId(thread: Thread): string {
  const ns = thread.meta?.channelId;
  return typeof ns === "string" && ns.length > 0 ? parse(ns).rawId : "INBOX";
}

/**
 * Display names for the addresses a reply might go to, keyed by lowercased
 * email: the resolved message's own headers first, then the thread's roster.
 * `resolveOutboundReplyRecipients` only attaches a display name for its
 * curated-recipient case (`note.recipients` resolved from a Plot contact) —
 * its header-driven cases take bare address strings in and return `name:
 * null`, by design (see that function's JSDoc). This fills that gap for the
 * header-derived cases so a reply addressed to `Jane Doe <jane@…>` still
 * reads the same as one sent from Apple Mail; the helper's own resolved name
 * (when present) always wins over this fallback.
 */
function displayNames(
  latest: Pick<ImapMessage, "from" | "to" | "cc"> | null,
  thread: Thread
): Map<string, string> {
  const names = new Map<string, string>();
  const add = (email: string | null | undefined, name: string | null | undefined) => {
    if (!email || !name) return;
    const key = email.toLowerCase();
    if (!names.has(key)) names.set(key, name);
  };
  for (const a of [...(latest?.from ?? []), ...(latest?.to ?? []), ...(latest?.cc ?? [])]) {
    add(a.address, a.name);
  }
  for (const c of thread.accessContacts ?? []) add(c.email, c.name);
  return names;
}

/**
 * Convert a resolved `Addressee` to the SMTP tool's address shape, falling
 * back to `names` (header/contact-derived) when the helper returned no name.
 */
function toSmtpAddress(a: Addressee, names: Map<string, string>): SmtpAddress {
  const name = a.name ?? names.get(a.address.toLowerCase()) ?? null;
  return name ? { address: a.address, name } : { address: a.address };
}

/** File ids of a note's `ActionType.file` actions, for outbound attachment collection. */
function fileActionIds(actions: Array<Action> | null | undefined): string[] {
  return (actions ?? [])
    .filter((a): a is Extract<Action, { type: ActionType.file }> => a.type === ActionType.file)
    .map((a) => a.fileId);
}

/**
 * Reply write-back. Resolves the thread's latest message from its own home
 * mailbox (`thread.meta.channelId`, best-effort, for threading headers +
 * reply-all recipients), sends via SMTP, and returns a NoteWriteBackResult.
 * Delivery failures return a `deliveryError` rather than throwing. The reply
 * note's key is set to the sent Message-ID so a Sent-mailbox re-ingest upserts
 * onto the same note (echo suppression by key idempotency).
 */
export async function onNoteCreatedFn(
  host: MailHost,
  note: Note,
  thread: Thread
): Promise<NoteWriteBackResult | void> {
  const rootId = mailRootId(thread);
  if (!rootId) return; // not one of our mail threads

  const selfEmails = new Set<string>([host.appleId.toLowerCase()]);

  // Resolve the thread's latest message from its home mailbox for threading
  // headers + reply-all recipients (best-effort). A transient IMAP failure
  // (connection cap under IDLE pressure, network blip) must NOT abort the send
  // or page — fall back to the accessContacts + root-id path.
  let resolved: ResolvedThread = { messages: [], uids: [], latest: null };
  try {
    const session = await connectIcloud(host);
    try {
      resolved = await resolveThreadMessages(
        host,
        session,
        mailChannelRawId(thread),
        rootId,
        thread.title
      );
    } finally {
      await host.imap.disconnect(session);
    }
  } catch {
    // Best-effort resolution; proceed with the reply-all/accessContacts fallback.
  }
  const latest = resolved.latest;

  // The author may be a different linked identity than the connected mailbox
  // (a second address of the same person). They must never receive their own
  // reply either. `note.recipients`, when present, is already self-excluded
  // across every linked identity by the runtime.
  const authorEmail = (thread.accessContacts ?? []).find(
    (c) => c.id === note.author?.id
  )?.email;
  if (authorEmail) selfEmails.add(authorEmail.toLowerCase());

  // The note's own access list, resolved to addresses. Under
  // `sharingModel: "message"` this is what carries mid-thread recipient
  // changes: someone added to this reply isn't on the original message's
  // headers, and someone the user dropped still is. Only used as the fallback
  // constraint — `note.recipients`, when the runtime resolved it, is
  // authoritative.
  let accessContactEmails: Set<string> | null = null;
  if (note.accessContacts != null) {
    const allowed = new Set<string>(note.accessContacts);
    accessContactEmails = new Set<string>();
    for (const c of thread.accessContacts ?? []) {
      if (allowed.has(c.id) && c.email) accessContactEmails.add(c.email.toLowerCase());
    }
  }

  // Original participants: From ∪ To → To, Cc → Cc. When the thread's
  // messages couldn't be resolved (transient IMAP failure), fall back to the
  // thread's roster so a reply still goes somewhere.
  const headerTo = latest
    ? [...(latest.from ?? []), ...(latest.to ?? [])].map((a) => a.address)
    : (thread.accessContacts ?? []).map((c) => c.email).filter((e): e is string => !!e);
  const headerCc = latest ? (latest.cc ?? []).map((a) => a.address) : [];

  // Resolve via the shared helper every `sharingModel: "message"` connector
  // uses, so recipient resolution isn't re-implemented (and re-broken) here.
  const resolvedRecipients = resolveOutboundReplyRecipients({
    recipients: note.recipients ?? null,
    accessContactEmails,
    headerTo,
    headerCc,
    selfEmails,
  });
  const names = displayNames(latest, thread);
  const recipients: OutboundRecipients = {
    to: resolvedRecipients.to.map((a) => toSmtpAddress(a, names)),
    cc: resolvedRecipients.cc.map((a) => toSmtpAddress(a, names)),
    bcc: resolvedRecipients.bcc.map((a) => toSmtpAddress(a, names)),
  };
  if (isEmpty(recipients)) {
    // Under the message sharing model a user can write a note on a mail
    // thread that is private to them (access list set, but naming nobody
    // else). That has nothing to send and nothing to report — flagging it
    // "Failed to send" would be wrong. Every other empty outcome is a reply
    // the user meant to go somewhere, so it still surfaces.
    const keptPrivate =
      note.accessContacts != null &&
      !note.accessContacts.some((id) => id !== note.author?.id);
    if (keptPrivate) return;
    return { deliveryError: { code: "no_recipients", message: "No one to reply to" } };
  }

  const inReplyTo = latest?.messageId ?? angle(rootId);
  const references = latest
    ? [...(latest.references ?? []), latest.messageId ?? angle(rootId)]
    : [angle(rootId)];

  const fileIds = fileActionIds(note.actions);
  const attachments =
    fileIds.length > 0 ? await collectFileAttachments(host, fileIds) : undefined;

  const message: SmtpMessage = {
    from: { address: host.appleId },
    to: recipients.to,
    cc: recipients.cc.length ? recipients.cc : undefined,
    bcc: recipients.bcc.length ? recipients.bcc : undefined,
    subject: replySubject(thread.title ?? latest?.subject),
    text: note.content ?? "",
    inReplyTo,
    references,
    ...(attachments && attachments.length > 0 ? { attachments } : {}),
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

/** Format an ImapAddress for a forwarded header line: "Name <address>" if a name is present, else just the address. */
function formatAddress(a: ImapAddress): string {
  return a.name ? `${a.name} <${a.address}>` : a.address;
}

/**
 * Build the "---------- Forwarded message ----------" attribution block's
 * header lines (From/Date/Subject/To) for a source message being forwarded,
 * mirroring the block Apple Mail's own UI inserts. Omits any header the
 * source message doesn't carry rather than emitting a blank line.
 */
function buildForwardedHeader(message: ImapMessage): string {
  const lines: string[] = [];
  const from = message.from && message.from.length > 0 ? message.from[0] : null;
  if (from) lines.push(`From: ${formatAddress(from)}`);
  if (message.date) lines.push(`Date: ${message.date.toUTCString()}`);
  if (message.subject) lines.push(`Subject: ${message.subject}`);
  if (message.to && message.to.length > 0) {
    lines.push(`To: ${message.to.map(formatAddress).join(", ")}`);
  }
  return lines.join("\n");
}

/**
 * Handles `onCreateLink` when `draft.forward` is set — the runtime is asking
 * the connector to reconstruct a native forward of an existing message
 * (declared via `LinkTypeConfig.supportsForward`) instead of falling back to
 * the generic blockquote forward. A forward is a brand-new message (new
 * thread, no In-Reply-To/References) whose body carries the forwarder's own
 * note on top of the quoted original, with the original's attachments
 * re-attached. Mirrors the compose path's idempotency guard and
 * delivery-error surfacing so a retried dispatch behaves the same way a
 * retried compose does.
 */
async function onCreateLinkForwardFn(
  host: MailHost,
  draft: CreateLinkDraft,
  forwardKey: string,
  now: Date = new Date()
): Promise<CreateLinkResult | null> {
  const recipients = composeRecipients(draft.recipients, draft.inviteEmails);
  if (isEmpty(recipients)) {
    return {
      originatingNote: {
        deliveryError: { code: "no_recipients", message: "No recipients" },
      },
    };
  }

  // A transient IMAP failure (connect, fetch original message/attachments)
  // must not throw+page — degrade like the reply and flag write-back paths
  // do: return a deliveryError so the note surfaces "Failed to send" with
  // Retry, and leave the dedup guard below unset so Retry re-sends. A
  // genuine null result (message not found) is handled OUTSIDE the try so it
  // still yields its own `not_found` error rather than being folded into
  // `imap_unavailable`.
  let found: { mailbox: string; message: ImapMessage } | null = null;
  let attachments: { fileName: string; mimeType: string; data: Uint8Array }[] = [];
  try {
    const session = await connectIcloud(host);
    try {
      found = await fetchOriginalMessage(host, session, forwardKey, draft.title, now);
      if (found) {
        attachments = await fetchOriginalAttachments(host, session, found.mailbox, found.message);
      }
    } finally {
      await host.imap.disconnect(session);
    }
  } catch {
    return {
      originatingNote: {
        deliveryError: {
          code: "imap_unavailable",
          message: "Couldn't reach iCloud to load the original message. Try again.",
        },
      },
    };
  }
  if (!found) {
    return {
      originatingNote: {
        deliveryError: {
          code: "not_found",
          message: "The original message could not be found — it may have been deleted.",
        },
      },
    };
  }

  const subject = draft.title.startsWith("Fwd:") ? draft.title : `Fwd: ${draft.title}`;
  const quoted = [
    "---------- Forwarded message ----------",
    buildForwardedHeader(found.message),
    "",
    bodyOf(found.message)?.content ?? "",
  ].join("\n");
  const noteContent = draft.noteContent ?? "";
  const text = noteContent.length > 0 ? `${noteContent}\n\n${quoted}` : quoted;

  // Content-hash dedup: same pattern + window as compose (below), but keyed
  // off the forward source so a re-invoked dispatch reuses the prior send
  // instead of forwarding a second time.
  const dedupKey = `forward:${fnv1aHex(
    JSON.stringify([
      "forward",
      forwardKey,
      subject,
      text,
      recipients.to.map((a) => a.address).sort(),
      recipients.cc.map((a) => a.address).sort(),
      recipients.bcc.map((a) => a.address).sort(),
    ])
  )}`;
  const prior = await host.get<{ rootId: string; at: number; text: string }>(dedupKey);
  if (prior && now.getTime() - prior.at < COMPOSE_DEDUP_WINDOW_MS) {
    return {
      ...composeLink(host, draft, subject, prior.rootId),
      originatingNote: { key: prior.rootId, externalContent: prior.text, deliveryError: null },
    };
  }

  const message: SmtpMessage = {
    from: { address: host.appleId },
    to: recipients.to,
    cc: recipients.cc.length ? recipients.cc : undefined,
    bcc: recipients.bcc.length ? recipients.bcc : undefined,
    subject,
    text,
    ...(attachments.length ? { attachments } : {}),
    // NO inReplyTo / references — a forward starts a new thread.
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
  // Store `text` alongside the dedup guard: unlike reply/compose (where the
  // sent SMTP text equals the stored note's content 1:1), a forward's sent
  // text = noteContent + the quoted attribution block + original body, but
  // the stored note only holds the clean `draft.noteContent`. Re-using this
  // exact `text` as the next `originatingNote.externalContent` on a dedup
  // hit keeps the sync baseline consistent with the one actually sent.
  await host.set(dedupKey, { rootId, at: now.getTime(), text });
  // `externalContent` establishes the sync baseline as exactly what iCloud's
  // Sent mailbox now stores for this note (the full sent `text`, quoted
  // original + attribution block included) — see the doc comment above the
  // dedup guard. Without this, the recent-window Sent rescan re-ingests the
  // sent message and `transformMessages` builds a note with the SAME key
  // (stripAngle(sent Message-ID) === rootId) and SAME source, whose content
  // is the full raw quoted blob; with no baseline to compare against, that
  // upsert would silently overwrite the clean `draft.noteContent` note this
  // hook just stored. This assumes the IMAP round-trip of the body is
  // lossless (the same assumption reply/compose already make); a more
  // robust echo-suppression marker (mirroring Gmail's `sent:<id>` flag,
  // which filters the sent note out of re-ingest entirely) is deferred.
  return {
    ...composeLink(host, draft, subject, rootId),
    originatingNote: { key: rootId, externalContent: text, deliveryError: null },
  };
}

/**
 * Compose write-back: send a brand-new email the user composed in Plot and
 * return a link rooted at the sent Message-ID (so the composed thread becomes
 * the mail thread root, and a Sent-mailbox re-ingest dedups by source). A
 * short content-hash window guards against a re-invoked create double-sending.
 * Delivery failures set `originatingNote.deliveryError` and return no source.
 *
 * When `draft.forward` is set (the link type declares `supportsForward`),
 * delegates to {@link onCreateLinkForwardFn} to reconstruct a native forward
 * of the source message instead of composing a brand-new email.
 */
export async function onCreateLinkFn(
  host: MailHost,
  draft: CreateLinkDraft,
  now: Date = new Date()
): Promise<CreateLinkResult | null> {
  if (draft.type !== "email") return null;

  if (draft.forward) return onCreateLinkForwardFn(host, draft, draft.forward.key, now);

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

  const fileIds = (draft.attachments ?? []).map((a) => a.fileId);
  const attachments =
    fileIds.length > 0 ? await collectFileAttachments(host, fileIds) : undefined;

  const message: SmtpMessage = {
    from: { address: host.appleId },
    to: recipients.to,
    cc: recipients.cc.length ? recipients.cc : undefined,
    bcc: recipients.bcc.length ? recipients.bcc : undefined,
    subject,
    text: body,
    ...(attachments && attachments.length > 0 ? { attachments } : {}),
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

/**
 * Set/clear a flag on every message of the thread, in the thread's own home
 * mailbox (`thread.meta.channelId`, resolved via `mailChannelRawId`). A
 * transient IMAP failure (connection cap under IDLE pressure, network blip)
 * must not page — but it also must not silently drop the write. Instead, the
 * desired flag state (and the mailbox to write it to) is persisted under a
 * small per-thread key and handed to the durable write-back drain
 * (`mailWritebackDrain` in apple.ts, via `host.queueWritebackDrain`) to
 * re-apply once IMAP is reachable again. Re-notifying the same id before the
 * drain fires (a fresh toggle) resets its attempt counter and simply
 * overwrites the stored payload — last-write-wins.
 *
 * Any direct call that resolves WITHOUT deferring — a successful IMAP write,
 * or a superseding no-op (no uids left to flag in the mailbox) — clears the
 * `writeback:${kind}:${rootId}` payload. This is required, not cosmetic: the
 * drain (`mailWritebackDrain` in apple.ts) skips re-applying when the payload
 * is absent (`if (!pending) continue`), but nothing else ever clears it. If a
 * failed toggle persists a payload + queues a drain, and the OPPOSITE toggle
 * then succeeds directly (without this clear), the stale payload survives and
 * the queued drain later re-applies the OLD, now-wrong operation.
 */
async function setThreadFlag(
  host: MailHost,
  thread: Thread,
  flag: string,
  operation: "add" | "remove"
): Promise<void> {
  const rootId = mailRootId(thread);
  if (!rootId) return;
  const kind = flag === "\\Seen" ? "read" : "todo";
  const mailbox = mailChannelRawId(thread);

  try {
    const session = await connectIcloud(host);
    try {
      const { uids } = await resolveThreadMessages(host, session, mailbox, rootId, thread.title);
      if (uids.length === 0) {
        // Nothing to flag — not a failure, but still a superseding
        // resolution: drop any stale pending payload from a prior failure.
        await host.clear(`writeback:${kind}:${rootId}`);
        return;
      }
      await host.imap.setFlags(session, uids, [flag], operation);
      // This direct write succeeded — supersede any stale pending payload so
      // the queued drain (if one is still pending from an earlier failure)
      // skips instead of re-applying the old operation.
      await host.clear(`writeback:${kind}:${rootId}`);
    } finally {
      await host.imap.disconnect(session);
    }
  } catch {
    await host.set(`writeback:${kind}:${rootId}`, { title: thread.title, mailbox, flag, operation });
    await host.queueWritebackDrain(`${kind}:${rootId}`);
  }
}

/**
 * Read-state write-back: mark the thread's messages (in its home mailbox)
 * \Seen (read) or clear it (unread). No echo guard is needed — the incremental read path only flips a
 * thread unread on a genuinely-new unseen UID, so our own \Seen write can't
 * bounce back.
 */
export async function onThreadReadFn(
  host: MailHost,
  thread: Thread,
  _actor: Actor,
  unread: boolean
): Promise<void> {
  await setThreadFlag(host, thread, "\\Seen", unread ? "remove" : "add");
}

/**
 * To-do write-back: mark the thread's messages (in its home mailbox) \Flagged
 * (to-do) or clear it. Bidirectional: the read path (`reconcileTodoFlags` in sync.ts)
 * also ingests \Flagged into Plot's to-do state, so an echo-dedup marker is
 * required here. The marker is set to the desired state BEFORE the IMAP
 * write — mirroring Gmail's `starred:<id>` ordering (`onThreadToDoFn` in
 * `google/src/mail/sync.ts`) — so the read pass that next re-fetches this
 * thread (poll or push-drain) sees `isFlagged === wasFlagged` for a change
 * that originated here, and does not re-propagate it back into Plot.
 *
 * Set unconditionally, even when the IMAP write itself defers to the
 * writeback retry queue (Task 5): the to-do state already lives in Plot, so
 * the marker should reflect that intent regardless of when — or whether —
 * the deferred write ultimately lands. If the deferred write eventually
 * drains successfully, the marker and IMAP converge with no user-visible
 * effect. But if it is instead POISON-DROPPED — retried and failed until
 * `mailWritebackDrain` (apple.ts) gives up after `maxAttempts` — the next
 * read pass (`reconcileTodoFlags` in sync.ts) sees the true, never-flagged
 * IMAP state disagree with this marker and silently flips Plot's to-do back
 * to match it. That is a one-way revert of the user's action, NOT a
 * self-correcting flip-flop: nothing subsequently restores the user's
 * intent. This is an accepted limitation (the same class Gmail's equivalent
 * write-back ships with), not something this connector attempts to fix.
 */
export async function onThreadToDoFn(
  host: MailHost,
  thread: Thread,
  _actor: Actor,
  todo: boolean,
  _options: { date?: Date }
): Promise<void> {
  const rootId = mailRootId(thread);
  if (!rootId) return;
  await host.set(`flagged:${rootId}`, todo);
  await setThreadFlag(host, thread, "\\Flagged", todo ? "add" : "remove");
}
