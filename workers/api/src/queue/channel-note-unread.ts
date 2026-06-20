import type { Kysely } from "kysely";

import type { DB } from "../db";
import type { Bindings } from "../env";
import { markThreadUnreadForOthers } from "../app/sync/notes";

/**
 * Fallback unread-marking for an incoming channel note when AI analysis did
 * not already write the unread signal (AI disabled / quota reached / empty
 * content / analysis error).
 *
 * Passes the note's `source_created_at` as `markThreadUnreadForOthers`'s
 * race-guard timestamp so `upsert_thread_state` preserves the read for any
 * recipient who already read the thread AFTER this note. Without it, the guard
 * is disabled and `read_at` is nulled unconditionally — so re-dispatching an
 * already-read incoming message (a connector re-sync, a note `seq` bump, or a
 * queue retry) re-marks the thread unread and clobbers the user's read on every
 * device. The AI path (`applyThreadState`) already supplies this guard; this is
 * the fallback's matching protection.
 */
export async function markChannelNoteUnreadFallback(
  env: Bindings,
  db: Kysely<DB>,
  note: { thread_id: string | null; source_created_at: string | Date | null },
  ownerId: string,
  analysisHandledUnread: boolean,
): Promise<void> {
  if (analysisHandledUnread || !note.thread_id) return;
  const noteCreatedAt = note.source_created_at
    ? new Date(note.source_created_at).toISOString()
    : undefined;
  await markThreadUnreadForOthers(env, db, note.thread_id, ownerId, noteCreatedAt);
}
