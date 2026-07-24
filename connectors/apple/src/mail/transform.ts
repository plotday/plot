import type { ImapAddress, ImapMessage } from "@plotday/twister/tools/imap";
import { ActionType, type Action, type NewContact, type NewLinkWithNotes } from "@plotday/twister";

import { parse } from "../product-channel";
import { buildAttachmentRef } from "./attachments";
import { isCalendarAttachment, type CalendarBundle } from "./calendar-bundle";
import { looksLikeHtml } from "./html";

/** Strip surrounding angle brackets and whitespace from a Message-ID. */
export function stripAngle(id: string): string {
  return id.replace(/[<>]/g, "").trim();
}

/** Thread root id: first Reference if present, else the message's own id. */
export function rootMessageId(msg: ImapMessage): string | null {
  const ref = msg.references && msg.references.length > 0 ? msg.references[0] : null;
  const raw = ref ?? msg.messageId ?? null;
  if (!raw) return null;
  const stripped = stripAngle(raw);
  return stripped.length > 0 ? stripped : null;
}

/** Global dedup key for a mail thread. */
export function mailSource(rootId: string): string {
  return `icloud-mail:thread:${rootId}`;
}

/**
 * An `ImapMessage` tagged with the mailbox it was fetched from. `sync.ts`
 * fetches every enabled mailbox plus Sent and merges them into ONE
 * `transformMessages` call (see the docstring below), so the mailbox tag is
 * the only thing that makes a message identifiable once the arrays are
 * combined — IMAP UIDs are unique only within a single mailbox, so `uid`
 * alone is ambiguous. It is load-bearing for attachment refs
 * (`buildAttachmentRef`), for `messageKey`, and for the Sent-only rule.
 */
export type MailMessage = ImapMessage & { mailbox: string };

/**
 * Identity of one fetched message across a merged multi-mailbox batch.
 *
 * IMAP UIDs are unique only WITHIN a mailbox, so `uid` alone cannot identify
 * a message once several folders are merged into a single pass: `Archive` uid
 * 42 and `INBOX` uid 42 are different messages. Qualifying by mailbox is what
 * keeps a stale unseen message in one folder from being mistaken for
 * newly-arrived mail in another (which would re-mark its thread unread on
 * every poll, forever).
 *
 * A space is a safe separator: IMAP mailbox names may contain `/` and `:`
 * but the value is only ever compared to another value built the same way,
 * so the format just has to be injective for the (mailbox, uid) pairs of a
 * single pass — and it is, since `uid` is numeric and cannot contain a space.
 */
export function messageKey(m: MailMessage): string {
  return `${m.mailbox} ${m.uid}`;
}

/**
 * Sort rank preferring INBOX over any other folder. Compared
 * case-insensitively because RFC 3501 defines INBOX case-insensitively and a
 * server may report it in any case (`channels.ts` normalizes the same way).
 */
function mailboxRank(mailbox: string): number {
  return mailbox.toUpperCase() === "INBOX" ? 0 : 1;
}

/**
 * Deterministic ordering for messages of one thread: oldest first, then a
 * stable tie-break on (INBOX-first, mailbox name, uid).
 *
 * The tie-break matters now that a pass merges several folders: two copies of
 * a same-second message arriving from different mailboxes would otherwise
 * order by whatever sequence the fetch loop happened to produce, making note
 * order — and the originator that drives `title`/`author` — depend on folder
 * iteration order rather than on the mail itself.
 */
function compareMessages(a: MailMessage, b: MailMessage): number {
  const byDate = (a.date?.getTime() ?? 0) - (b.date?.getTime() ?? 0);
  if (byDate !== 0) return byDate;
  const byRank = mailboxRank(a.mailbox) - mailboxRank(b.mailbox);
  if (byRank !== 0) return byRank;
  if (a.mailbox !== b.mailbox) return a.mailbox < b.mailbox ? -1 : 1;
  return a.uid - b.uid;
}

/** The note key for one message: its stripped Message-ID, else a uid fallback. */
function noteKeyOf(m: MailMessage): string {
  return m.messageId ? stripAngle(m.messageId) : `uid-${m.uid}`;
}

/**
 * Collapse copies of the SAME message that a merged pass fetched from two
 * different folders (the user keeps a copy in a project folder as well as
 * INBOX, say). Both copies carry the same Message-ID, so they'd produce two
 * notes with the same `key` in one batch — the last one written would win
 * non-deterministically — and their `\Seen`/`\Flagged` flags can differ,
 * perturbing the thread's read state and to-do reconciliation.
 *
 * Which copy survives must not depend on fetch order, or the thread would
 * churn between passes. Preference, in order:
 *  1. the copy in the thread's own home mailbox (`homeMailbox`, derived from
 *     the resolved channel) — that folder is where the thread "lives";
 *  2. otherwise the first by (INBOX-first, mailbox name, uid).
 *
 * Rule 1 only discriminates when EXACTLY ONE of the two copies is in the
 * home mailbox. When both are (duplicate delivery into the same folder) or
 * neither is, it can't pick a winner — those cases fall through to rule 2's
 * `compareCopies` tie-break, which is itself order-independent, so the
 * result still doesn't depend on fetch order.
 *
 * Messages with no Message-ID fall back to a `uid-<uid>` key (see
 * `noteKeyOf`) that is NOT mailbox-qualified. Such messages ARE deduped by
 * this function — just on a key that can collide: two genuinely DIFFERENT
 * Message-ID-less messages in different mailboxes that happen to share a uid
 * AND a thread root are treated as one message, and one is silently
 * dropped — it contributes no note of its own, and its participants and
 * flags are absent from the union/`allSeen`. Known residual: Message-ID-less
 * mail reaching this path at all is vanishingly rare, and closing it would
 * mean widening the note-key shape itself, which is out of scope here.
 */
function dedupeCopies(msgs: MailMessage[], homeMailbox: string | null): MailMessage[] {
  const byKey = new Map<string, MailMessage>();
  for (const m of msgs) {
    const key = noteKeyOf(m);
    const held = byKey.get(key);
    if (!held) {
      byKey.set(key, m);
      continue;
    }
    const heldIsHome = held.mailbox === homeMailbox;
    const mIsHome = m.mailbox === homeMailbox;
    if (heldIsHome !== mIsHome) {
      // Exactly one copy is in the home mailbox — it wins outright,
      // regardless of which was seen first.
      if (mIsHome) byKey.set(key, m);
      continue;
    }
    // Both (or neither) copy is in the home mailbox, so rule 1 can't
    // discriminate — this is precisely the case that used to fall through to
    // "whichever was first in `msgs`" (order-dependent). Use the
    // order-independent tie-break instead.
    if (compareCopies(m, held) < 0) byKey.set(key, m);
  }
  return [...byKey.values()];
}

/** Tie-break between two copies of one message: INBOX first, then name, then uid. */
function compareCopies(a: MailMessage, b: MailMessage): number {
  const byRank = mailboxRank(a.mailbox) - mailboxRank(b.mailbox);
  if (byRank !== 0) return byRank;
  if (a.mailbox !== b.mailbox) return a.mailbox < b.mailbox ? -1 : 1;
  return a.uid - b.uid;
}

/**
 * Build this message's `fileRef` actions from its attachment parts, or
 * undefined when none. Skips an inline calendar part (text/calendar,
 * application/ics) whose `fileName` is IMAP-parse's synthesized placeholder
 * `"attachment"` (see `imap-parse.ts`'s `fileName ?? "attachment"`) — every
 * meeting invite/update carries one of these, and mapping it to a fileRef
 * action would render an extensionless, meaningless "attachment" download
 * chip on emails that don't even bundle (bare invites). A genuinely named
 * calendar attachment (e.g. a forwarded `invite.ics`) still appears
 * normally — only the synthesized-name case is suppressed.
 */
function attachmentActions(m: MailMessage): Action[] | undefined {
  if (!m.attachments || m.attachments.length === 0) return undefined;
  const actions = m.attachments
    .filter((a) => !(isCalendarAttachment(a.mimeType) && a.fileName === "attachment"))
    .map((a) => ({
      type: ActionType.fileRef as ActionType.fileRef,
      ref: buildAttachmentRef(m.mailbox, m.uid, a.partNumber),
      fileName: a.fileName,
      fileSize: a.size,
      mimeType: a.mimeType,
    }));
  return actions.length > 0 ? actions : undefined;
}

export type TransformCtx = {
  /** The connection owner's Apple ID (their own address). */
  appleId: string;
  /**
   * The namespaced mail channel each thread root is homed to, e.g.
   * `"mail:Archive"` — the link's top-level `channelId` AND its
   * `meta.syncableId` both come from here, and the two must stay equal
   * because disable-time archiving ANDs both filters.
   *
   * Per ROOT, not per batch: one merged pass covers every enabled folder, so
   * there is no single channel for the call. The caller resolves and persists
   * a home channel per thread (rather than deriving it from whichever
   * messages happen to be inside this pass's window) so the value is stable
   * across passes. Every root present in `messages` must have an entry; a
   * root without one is skipped with a warning rather than emitted with a
   * null channel, which would be un-archivable.
   */
  channelByRoot: Map<string, string>;
  /**
   * Thread roots being ingested for the first time by a HISTORICAL backfill.
   * These get `unread: false, archived: false`, the standard discipline that
   * stops a bulk import of old mail from spamming notifications.
   *
   * Per ROOT, not per batch: one merged pass can backfill a newly-enabled
   * folder while incrementally syncing the folders that already have a
   * cursor. A batch-wide `true` would clear genuine unread state and
   * un-archive threads the user archived; a batch-wide `false` would leave
   * the newly-enabled folder's historical threads with no `unread` key on
   * INSERT, so the database default (unread) applies — the spam this exists
   * to prevent. A root that is new to Plot but arrived as live mail is NOT in
   * this set.
   */
  initialRoots: Set<string>;
  /**
   * Messages that are NEW this pass, identified by `messageKey()` —
   * `"<mailbox> <uid>"`, NOT a bare uid, because IMAP UIDs are unique only
   * within a mailbox (see `messageKey`).
   *
   * Drives the incremental unread decision: a thread is only (re)marked
   * unread by a genuinely new unseen message. The recent-window `\Seen`
   * rescan re-fetches already-synced messages to propagate reads done in
   * Apple Mail — but those must NEVER re-assert unread, or a message read in
   * Plot yet still unseen on IMAP would flip back to unread on every poll.
   *
   * Must never contain a Sent message: mail the owner sent must not mark
   * their own thread unread.
   */
  newMessages: Set<string>;
  /**
   * The raw Sent mailbox name for this pass, when the account has one.
   *
   * Used only for the Sent-only rule: when every message a thread
   * contributed to this batch came from Sent, the batch carries no
   * information about the thread's real subject or read state — the inbound
   * messages simply fall outside the fetched window — so `title` and `unread`
   * are both omitted rather than recomputed from the owner's own reply. Both
   * fields are last-writer-wins on upsert, and a present key of ANY value
   * overwrites, so the keys must be absent, not null/empty.
   */
  sentMailbox?: string | null;
  /**
   * Per-thread-root calendar-invite bundling decisions, computed by
   * `sync.ts`'s `detectCalendarBundles` (which fetches and classifies any
   * `text/calendar`/`application/ics` attachment — I/O that this pure
   * function must not do itself). When a thread's root id has an entry, its
   * link bundles onto the referenced calendar event's thread via the shared
   * `icaluid:<uid>` alias — see the `sources` doc on `Link` in
   * `@plotday/twister/plot`.
   */
  calendarBundles?: Map<string, CalendarBundle>;
};

function toContact(a: ImapAddress): NewContact {
  return { email: a.address, name: a.name ?? "" };
}

function isSeen(msg: ImapMessage): boolean {
  return msg.flags.includes("\\Seen");
}

/**
 * The recipient set for ONE message: its own From/To/Cc, plus the connection
 * owner. The email link type declares `sharingModel: "message"`, whose
 * contract is that every ingested note carries its own non-null access list —
 * so a person added to a later reply sees that reply and everything after it,
 * but not the conversation that preceded them.
 *
 * The owner is added explicitly rather than relying on the runtime's
 * account-contact injection: plenty of mail the owner receives names them in
 * no header at all (mailing lists, aliases, Bcc), and under the message model
 * a note without them in its access list is redacted FROM THEM. Their own
 * address is the one participant this connector always knows, so we never
 * make their own mail depend on identity resolution succeeding.
 *
 * Bcc recipients are deliberately absent — IMAP doesn't expose them on
 * received mail, and inferring them would leak a blind copy to the thread.
 */
function messageContacts(msg: MailMessage, ownEmail: string): NewContact[] {
  const byEmail = new Map<string, NewContact>();
  for (const a of [...(msg.from ?? []), ...(msg.to ?? []), ...(msg.cc ?? [])]) {
    byEmail.set(a.address.toLowerCase(), toContact(a));
  }
  if (!byEmail.has(ownEmail)) byEmail.set(ownEmail, { email: ownEmail, name: "" });
  return [...byEmail.values()];
}

/** Pick body content + contentType for one message. */
export function bodyOf(msg: ImapMessage): { content: string; contentType: "html" | "text" } | null {
  if (msg.bodyHtml && msg.bodyHtml.trim().length > 0) {
    return { content: msg.bodyHtml, contentType: "html" };
  }
  if (msg.bodyText && msg.bodyText.trim().length > 0) {
    return {
      content: msg.bodyText,
      contentType: looksLikeHtml(msg.bodyText) ? "html" : "text",
    };
  }
  return null;
}

/**
 * Group a batch of messages by thread root and build one NewLinkWithNotes per
 * thread. Notes are keyed by (stripped) Message-ID for idempotent upsert; the
 * link author is the earliest message's sender; accessContacts is the union of
 * every participant seen; the owner's own messages are credited via
 * authoredBySelf.
 *
 * `messages` must be the COMPLETE visible message set for every thread it
 * touches — every enabled mailbox plus Sent — in a single call. `unread`,
 * `title` and the originator are all derived from only the messages handed to
 * one call, so two calls for the same thread each recompute them in isolation
 * and whichever is saved last wins: an owner Sent reply saved after an unseen
 * inbound one incorrectly clears `unread`, and a folder holding only part of
 * a conversation rewrites its title from a partial view. Merging every
 * mailbox into one call is what makes a thread's rebuild deterministic. See
 * `sync.ts`.
 *
 * Owner messages need no batch-level flag: iCloud Sent messages carry the
 * owner's address in `From`, so per-message address comparison identifies
 * them. (Alias-`From` sent mail attributes to the alias's contact instead of
 * `authoredBySelf` — an accepted minor edge case.)
 */
export function transformMessages(
  messages: MailMessage[],
  ctx: TransformCtx
): NewLinkWithNotes[] {
  const ownEmail = ctx.appleId.toLowerCase();
  const sentMailbox = ctx.sentMailbox ?? null;
  // Group by thread root (skip messages with no id to thread on).
  const byRoot = new Map<string, MailMessage[]>();
  for (const m of messages) {
    const root = rootMessageId(m);
    if (!root) continue;
    const list = byRoot.get(root) ?? [];
    list.push(m);
    byRoot.set(root, list);
  }

  const links: NewLinkWithNotes[] = [];
  for (const [root, allCopies] of byRoot.entries()) {
    // The thread's home channel. A missing entry means the caller failed its
    // contract; emitting the link anyway would need a null channelId, which
    // never matches disable-time archiving and never seeds the thread's
    // topic. Skip the root instead so the rest of the pass still lands.
    const channelId = ctx.channelByRoot.get(root);
    if (!channelId) {
      console.warn(`[Apple Mail] No channel resolved for thread root ${root}; skipping`);
      continue;
    }
    const homeMailbox = parse(channelId).rawId;

    // Collapse copies of one message held in two folders BEFORE anything is
    // derived from the set — duplicates would double a note key and perturb
    // the read/flag state (see dedupeCopies) — then order deterministically,
    // so nothing downstream (note order, originator, the participant union)
    // depends on which mailbox the merged pass happened to fetch first.
    const msgs = dedupeCopies(allCopies, homeMailbox).sort(compareMessages);

    // Earliest message drives the thread's title + author.
    const originator = msgs[0];
    const originatorFrom = originator.from && originator.from[0] ? originator.from[0] : null;

    // Union of participants for thread access.
    const participants = new Map<string, NewContact>();
    for (const m of msgs) {
      for (const a of [...(m.from ?? []), ...(m.to ?? []), ...(m.cc ?? [])]) {
        participants.set(a.address.toLowerCase(), toContact(a));
      }
    }

    const notes = msgs.map((m) => {
      const key = noteKeyOf(m);
      const body = bodyOf(m);
      const from = m.from && m.from[0] ? m.from[0] : null;
      const isOwner = from?.address.toLowerCase() === ownEmail;
      const actions = attachmentActions(m);
      return {
        key,
        content: body?.content ?? "",
        contentType: body?.contentType ?? ("text" as const),
        created: m.date,
        // Owner's own messages: credit via authoredBySelf, leave author unset.
        ...(isOwner
          ? { authoredBySelf: true as const }
          : { author: from ? toContact(from) : null }),
        ...(actions ? { actions } : {}),
        accessContacts: messageContacts(m, ownEmail),
      };
    });

    // Incremental read-state (see TransformCtx.newMessages):
    //  - every message seen        → mark read (a read done in Apple Mail)
    //  - a NEW unseen message      → mark unread (genuinely new mail)
    //  - only existing unseen mail → leave `unread` untouched, so IMAP's stale
    //    unseen flag can't clobber a read the user did in Plot.
    // Newness is matched on `messageKey` (mailbox + uid), never on the bare
    // uid: a merged pass sees several mailboxes at once, and a bare-uid match
    // would let an old unseen message in one folder inherit the "new" status
    // of an unrelated message that happens to share its uid in another —
    // re-marking the thread unread on every single poll.
    const allSeen = msgs.every((m) => isSeen(m));
    const hasNewUnseen = msgs.some(
      (m) => !isSeen(m) && ctx.newMessages.has(messageKey(m))
    );
    const incrementalRead: { unread?: boolean } = allSeen
      ? { unread: false }
      : hasNewUnseen
        ? { unread: true }
        : {};

    // Sent-only rule (see TransformCtx.sentMailbox): this pass saw nothing of
    // the thread but the owner's own outbound copies, so it knows neither the
    // real subject nor the read state. Omit both keys rather than assert a
    // value derived from half the conversation — UNLESS the root is in
    // `initialRoots`, in which case `initialRoots` wins for BOTH `unread` AND
    // `title`. Same reasoning both times: omitting a key only *preserves* a
    // value when the row already exists. On INSERT (a root Plot has never
    // seen) an omitted key falls through to the runtime's own default —
    // `unread` defaults to true (spam; closed below by `initialRoots` taking
    // precedence over `sentOnly`), and `title` has NO default at all: the
    // runtime substitutes the literal placeholder "Untitled",
    // PERMANENTLY, since every later pass for a still-Sent-only thread would
    // also omit the key (`thread-helpers.ts`'s
    // `cleanTitle(activity.title?.trim() || "Untitled")`). A degraded
    // "Re: …" subject from the Sent copy is strictly better than "Untitled",
    // and gets overwritten with the real subject the moment an inbound
    // message enters the window. See `sync.test.ts`'s "never 'Untitled'"
    // assertion for the same trap on the calendar-bundle path.
    //
    // Computed over `allCopies` (the pre-dedupe set), not `msgs`: dedupe's
    // home-mailbox preference could otherwise flip this in the (currently
    // unreachable, but not yet impossible) case where the resolved home
    // mailbox is itself a Sent folder — defensive, no behavioural difference
    // today.
    const sentOnly = sentMailbox !== null && allCopies.every((m) => m.mailbox === sentMailbox);
    const sentOnlyKnown = sentOnly && !ctx.initialRoots.has(root);
    const readState: { unread?: boolean; archived?: boolean } = ctx.initialRoots.has(root)
      ? { unread: false, archived: false }
      : sentOnly
        ? {}
        : incrementalRead;

    // Calendar thread bundling (see TransformCtx.calendarBundles doc): when
    // this thread's root was classified as a cancellation/update ICS,
    // ALWAYS bundle onto the calendar event's thread via the shared
    // `icaluid:<uid>` alias — that convergence must never be skipped, or
    // the mail and calendar sides would never share a thread. Whether
    // `title` is also set depends on `calendarBundle.eventKnown` (see its
    // doc in calendar-bundle.ts):
    //  - eventKnown true (the calendar product has already synced an event
    //    for this UID): OMIT `title` entirely. `title` is last-writer-wins
    //    on a bundled thread (unlike `author_id`, which is first-writer-
    //    wins), so setting it here (even to the correct-looking raw
    //    subject) would clobber the event's title back to the email
    //    subject on every mail sync pass that runs after a calendar pass.
    //    Per plot.ts's `NewLinkWithNotes.title` doc: "Omit to preserve the
    //    existing title." The key must be ABSENT, not `null`/`""` — a
    //    present key of any value still overwrites.
    //  - eventKnown false (no synced event yet — mail-only setup, a
    //    cancelled-before-sync event, an out-of-window/disabled calendar,
    //    or the calendar simply hasn't synced this pass yet): SET `title`
    //    from the subject, same as an unbundled thread. Otherwise the
    //    runtime's INSERT path has no title to fall back to and substitutes
    //    the literal placeholder "Untitled" — permanently, since a later
    //    mail pass would keep omitting the key. A later calendar sync (if
    //    one ever happens) still sets the real title unconditionally, so
    //    this never causes a stale title to stick around.
    //
    // `sentOnlyKnown` (not `sentOnly`) gates the OTHER `title` omission below,
    // for the identical "never leave an INSERT titleless" reason — see the
    // Sent-only rule comment above `sentOnly`'s declaration.
    const calendarBundle = ctx.calendarBundles?.get(root);
    const link: NewLinkWithNotes = {
      source: mailSource(root),
      type: "email",
      // channelId and meta.syncableId must stay EQUAL: disable-time archiving
      // filters on both together, so a mismatch makes the link unreachable.
      channelId,
      accessContacts: [...participants.values()],
      meta: {
        syncProvider: "apple-mail",
        syncableId: channelId,
        rootMessageId: root,
      },
      notes,
      // Thread author = originating sender (the owner's own address for
      // owner-sent threads); explicit null when the sender is unknown, so a
      // From-less message is never mis-credited to the connector.
      author: originatorFrom ? toContact(originatorFrom) : null,
      ...readState,
      ...(calendarBundle ? { sources: [`icaluid:${calendarBundle.uid}`] } : {}),
      ...(calendarBundle?.eventKnown || sentOnlyKnown
        ? {}
        : { title: originator.subject ?? "" }),
    };
    links.push(link);
  }
  return links;
}
