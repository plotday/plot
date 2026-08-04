/**
 * The fold itself: decide, compose, save, record — in the one order that is
 * correct — for a single attendee response.
 *
 * The predicates in `./rsvp-note` each answer one question and enforce no
 * order between them. Every connector that folds responses onto event threads
 * needs the same sequence around them, and getting the sequence wrong is not
 * cosmetic: it re-raises unread on threads people have already read, or leaves
 * the marker describing something other than what the event thread carries.
 * `foldRsvp` owns that sequence so no caller has to restate it.
 */

import type { NewNote } from "@plotday/twister";

import {
  alreadyFolded,
  composeRsvpNote,
  isNonAcceptance,
  priorRsvpKey,
  shouldEmitRsvpNote,
  type RsvpReply,
} from "./rsvp-note";

/**
 * What `foldRsvp` did with one response.
 *
 * Every outcome means "this message has been dealt with as a response" — the
 * caller drops its note from the mail thread in all three cases. A bare
 * acceptance is `"suppressed"`, not "ignored": it belongs on the event, and
 * the event's guest list already shows it, so the right note is no note.
 */
export type RsvpFoldOutcome =
  /** The stored marker already records this exact response; nothing written. */
  | "already-folded"
  /** Nothing new to say (a bare acceptance); no note, no marker. */
  | "suppressed"
  /** A note was saved and the marker updated to this response. */
  | "emitted";

/**
 * The parts of the emitted note only the connector can supply. Everything
 * else about the note — its content, its target thread, its author, that it
 * is markdown and deferred — is the shared fold rule and is set here.
 */
export type RsvpNoteFields = {
  /**
   * `note.key`, so a re-delivered response upserts rather than duplicating.
   * Each connector derives it from its own message identity.
   */
  key: string;
  /**
   * `note.created` — the response message's own timestamp. Omit when the
   * provider gave none; the field is then left off the note entirely rather
   * than sent as an explicit `undefined`.
   */
  created?: Date;
  /**
   * `note.unread`. Always passed explicitly, on every path: an omitted flag
   * does NOT mean "leave read state alone" — attaching a note already marks
   * the thread unread for every recipient except its author, so only an
   * explicit `false` overrides it. Connectors pass `false` for responses
   * ingested from history on first connect, `true` for live mail.
   */
  unread: boolean;
};

export type FoldRsvpOptions = {
  /**
   * The event's iCalendar UID. Addresses the event thread (`icaluid:<uid>`)
   * and scopes the fold marker. Read from the response's own calendar part,
   * not from the attendee line.
   */
  uid: string;
  /** The attendee's response. */
  reply: RsvpReply;
  /** See {@link RsvpNoteFields}. */
  note: RsvpNoteFields;
  /**
   * Read the stored fold marker for `key`. Injected because connectors read
   * their state differently — directly, or from a per-pass cache.
   *
   * Read on every response, not just a bare acceptance: the repeat check
   * needs the stored value on every path, so there is no cheaper path that
   * skips this round-trip.
   */
  readMarker: (key: string) => Promise<string | null | undefined>;
  /**
   * Record `partstat` under `key`. Called ONLY on the emitting path, after
   * the note is saved, and regardless of what `saveNote` returned — a
   * deferred note returns no id, and gating on it would leave a deferred
   * decline unrecorded forever, wrongly treating a later bare acceptance as
   * reversing nothing.
   *
   * Injected because durability differs by connector: writing through
   * immediately is the simple choice, while a connector that folds many
   * responses in one pass may collect the markers and flush them in a single
   * batched write. Batching carries two requirements, and missing either one
   * re-emits notes and re-raises unread on threads people have already read:
   *
   * 1. **Flush even when a later response throws** (a `finally`, not the happy
   *    path), or the markers of responses already written are lost with it.
   * 2. **Dedupe repeat deliveries WITHIN the pass by other means.** A batched
   *    marker is invisible to `readMarker` until it is flushed, so the same
   *    response reaching this function twice in one pass reads the pre-pass
   *    value both times, looks un-folded both times, and is emitted twice. A
   *    connector that can see one message more than once per pass — two
   *    mailbox copies of it, a conversation re-fetched under two ids — needs
   *    its own in-pass guard.
   */
  writeMarker: (
    key: string,
    partstat: RsvpReply["partstat"]
  ) => void | Promise<void>;
  /**
   * Save the composed note. Injected rather than taking a tool handle so this
   * library needs no runtime dependency on the SDK.
   *
   * The return value is deliberately not consulted: the note is deferred, so
   * `null` means "held until the event thread appears", not "rejected".
   */
  saveNote: (note: NewNote) => Promise<unknown>;
};

/**
 * Fold one attendee response onto its event's thread.
 *
 * The order below is the whole point of this function, and it is the order the
 * predicates document but cannot enforce:
 *
 * 1. **Read the marker.** It records the last response this connector actually
 *    folded onto the event thread for this attendee on this event or
 *    occurrence — see {@link priorRsvpKey}.
 * 2. **{@link alreadyFolded} FIRST.** Providers re-deliver the same response
 *    routinely: a mail subscription that fires on `updated` as well as
 *    `created`, a history replay, a backfill overlap, a re-scan window that
 *    re-reads the same message on every pass. The note upserts by key, so
 *    re-saving it would not duplicate it — but its unread intent is applied
 *    again and drags the thread back to unread for everyone who had read it.
 *    Comparing against the stored partstat (not merely its presence) means a
 *    genuine CHANGE of response is never caught by this; the accepted cost is
 *    that an attendee who edits only their comment on an unchanged response
 *    gets no updated note.
 * 3. **Only then decide whether to emit**, via `shouldEmitRsvpNote(reply,
 *    isNonAcceptance(stored))`. A bare acceptance says nothing the event's
 *    guest list does not already show, and writing no note is the ONLY way to
 *    keep it from marking the thread unread — attaching a note surfaces the
 *    thread as unread for every recipient except the note's author, and no
 *    field passed to `saveNote` suppresses that.
 * 4. **Write the marker only on the emitting path.** Never on the suppressed
 *    path, and never before the note is saved, or the marker stops describing
 *    what the event thread actually carries. It is written for every emitted
 *    response, acceptances included — that stored `"ACCEPTED"` is what lets a
 *    later repeat of the same acceptance be recognised in step 2.
 *
 * The note itself is addressed by `{ source: "icaluid:<uid>" }` and deferred:
 * `saveNote` resolves nothing when the calendar event has not synced yet, so
 * the platform holds the note and attaches it once that thread appears.
 *
 * Every outcome means the response has been dealt with — see
 * {@link RsvpFoldOutcome}. Callers do their own "this message was folded"
 * bookkeeping from that, because what they must record (an in-pass set,
 * durable per-thread metadata, or both) is connector-specific.
 */
export async function foldRsvp({
  uid,
  reply,
  note,
  readMarker,
  writeMarker,
  saveNote,
}: FoldRsvpOptions): Promise<RsvpFoldOutcome> {
  const markerKey = priorRsvpKey(uid, reply.attendeeEmail, reply.occurrence);
  const stored = await readMarker(markerKey);

  if (alreadyFolded(stored, reply)) return "already-folded";
  if (!shouldEmitRsvpNote(reply, isNonAcceptance(stored))) return "suppressed";

  await saveNote({
    thread: { source: `icaluid:${uid}` },
    key: note.key,
    content: composeRsvpNote(reply),
    contentType: "markdown",
    ...(note.created ? { created: note.created } : {}),
    author: {
      email: reply.attendeeEmail,
      ...(reply.attendeeName ? { name: reply.attendeeName } : {}),
    },
    unread: note.unread,
    deferUntilThread: true,
  });

  await writeMarker(markerKey, reply.partstat);
  return "emitted";
}
