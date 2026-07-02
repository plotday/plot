import { PostHog } from "posthog-node";
import { sql } from "kysely";

import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import { withDb, type DB, type Kysely } from "../db";
import {
  markThreadUnreadForOthers,
  noteVisibleUserIds,
  isScopedNote,
} from "../app/sync/notes";
import {
  dispatchCreateLink,
  resolveCreateLinkContacts,
  noteActionsToAttachments,
  parsePendingCreateLink,
} from "../app/sync/create-link-dispatch";

/** Bounded batch per tick — the sweep runs every minute, so a backlog larger
 * than this simply drains across ticks. */
const BATCH_LIMIT = 100;

export type ClaimedNote = {
  id: string;
  thread_id: string;
  created_by: string;
  content: string | null;
  actions: unknown;
  mentions: string[] | null;
  access_contacts: string[] | null;
  access_groups: string[] | null;
};

export type ReleasedThread = {
  id: string;
  title: string | null;
  contacts: string[] | null;
  groups: string[] | null;
  pending_create_link: unknown;
};

/**
 * Claim due held notes by atomically nulling `send_at`, and clear the
 * mirrored hold on their parent threads. The caller supplies the transaction
 * — both UPDATEs must commit together so a held thread shell can never
 * outlive its released note. Exported for tests.
 */
export async function claimDueScheduledNotes(
  trx: Kysely<DB>,
  limit: number = BATCH_LIMIT,
): Promise<{ notes: ClaimedNote[]; threads: ReleasedThread[] }> {
  const claimed = await sql<ClaimedNote>`
    UPDATE note SET send_at = NULL
    WHERE id IN (
      SELECT id FROM note
      WHERE send_at IS NOT NULL
        AND send_at <= now()
        AND draft = FALSE
        AND archived_at IS NULL
      ORDER BY send_at ASC
      LIMIT ${limit}
      FOR UPDATE SKIP LOCKED
    )
    RETURNING id, thread_id, created_by, content, actions, mentions,
      access_contacts, access_groups
  `.execute(trx);

  if (claimed.rows.length === 0) {
    return { notes: [], threads: [] };
  }

  const threadIds = [...new Set(claimed.rows.map((n) => n.thread_id))];
  const releasedThreads = await sql<ReleasedThread>`
    UPDATE thread SET send_at = NULL
    WHERE id = ANY(${threadIds}::uuid[])
      AND send_at IS NOT NULL
    RETURNING id, title, contacts, groups, pending_create_link
  `.execute(trx);

  return { notes: claimed.rows, threads: releasedThreads.rows };
}

/**
 * Scheduled-send release sweep. Runs on the 1-minute cron.
 *
 * A note authored with a future `send_at` is HELD: visible only to its author
 * and excluded from every dispatch view, the thread activity/unread trigger,
 * and the POST /sync/notes side effects. This sweep is the single place a held
 * note goes live:
 *
 * 1. CLAIM — atomically null `send_at` on due notes (`send_at <= now()`,
 *    non-draft, non-archived). `send_at IS NOT NULL` in the predicate is the
 *    idempotency marker: a claimed note can never be re-selected, and two
 *    overlapping ticks serialize on the row locks (FOR UPDATE SKIP LOCKED).
 *    The UPDATE bumps note.seq (set_note_updated_at) so clients resync the
 *    sent state, and fires update_thread_on_note_change (send_at is in the
 *    trigger's UPDATE OF list) so the thread surfaces / recipients unread at
 *    the moment of release. In the same transaction the parent thread's
 *    mirrored `send_at` (held thread shell for a scheduled new-thread
 *    compose) is cleared, re-emitting the thread to recipients atomically
 *    with the note.
 *
 * 2. DISPATCH — post-commit, best-effort. The note is already live and
 *    view-qualified, so a crash here is recovered by the next TwistSync wake
 *    (same loss class as the in-request waitUntil dispatches):
 *    - wake mention twists' TWIST_SYNC (reply/mention dispatch);
 *    - wake link-connector TwistSyncs on the thread (channel write-back);
 *    - deferred compose: a held new-connector-thread compose skipped its
 *      in-request dispatchCreateLink — perform it now from the
 *      thread.pending_create_link stash (rebuilt the way note-retry-send
 *      does);
 *    - unread/push fan-out: scoped notes were unread-marked by the trigger
 *      (push only); unscoped notes take markThreadUnreadForOthers — the same
 *      deterministic AI-skip fallback POST /sync/notes uses when analysis is
 *      unavailable. AI note analysis is deliberately not re-run at release.
 */
export async function publishScheduledNotes(
  env: Bindings,
  ctx: ExecutionContext,
): Promise<void> {
  const logger = createLogger({ operation: "publishScheduledNotes" });
  const postHog = new PostHog(env.POSTHOG_API_KEY, {
    host: "https://us.i.posthog.com",
    disabled: !env.POSTHOG_API_KEY,
  });

  try {
    await withDb(env, async (db) => {
      // Phase 1: claim. One transaction so a held thread shell can never
      // outlive its released note (that would deliver the note into a thread
      // recipients still can't see).
      const { notes, threads } = await db
        .transaction()
        .execute((trx) => claimDueScheduledNotes(trx));

      if (notes.length === 0) return;
      logger.info("Released scheduled notes", {
        count: notes.length,
        released_threads: threads.length,
      });

      // Phase 2: dispatch, per note, isolated so one failure doesn't strand
      // the rest of the batch.
      const releasedThreadsById = new Map(threads.map((t) => [t.id, t]));
      for (const note of notes) {
        try {
          await dispatchReleasedNote(
            env,
            ctx,
            db,
            note,
            releasedThreadsById.get(note.thread_id) ?? null,
            logger,
          );
        } catch (error) {
          logger.error("Failed to dispatch released note", error as Error, {
            note_id: note.id,
            thread_id: note.thread_id,
          });
          postHog.captureException(error as Error, undefined, {
            context: "publishScheduledNotes",
            note_id: note.id,
          });
        }
      }
    });
  } finally {
    ctx.waitUntil(postHog.shutdown());
  }
}

async function dispatchReleasedNote(
  env: Bindings,
  ctx: ExecutionContext,
  db: Kysely<DB>,
  note: ClaimedNote,
  releasedThread: ReleasedThread | null,
  logger: ReturnType<typeof createLogger>,
): Promise<void> {
  // Scheduled notes are always user-authored, so created_by is the user id.
  const authorUserId = note.created_by;

  // Wake mention twists (reply/mention dispatch — mirrors POST /sync/notes).
  const mentions = note.mentions ?? [];
  if (mentions.length > 0) {
    const mentionTwists = await db
      .selectFrom("twist_instance")
      .select("id")
      .where("id", "in", mentions)
      .where("archived_at", "is", null)
      .execute();
    for (const twist of mentionTwists) {
      await notifyTwistSync(env, twist.id, logger);
    }
  }

  // Wake connectors with links on this thread (channel write-back: the
  // released note now qualifies in twist_instance_channel_note_create).
  const linkConnectors = await db
    .selectFrom("link as l")
    .innerJoin("twist_instance as ti", "ti.id", "l.created_by")
    .select("ti.id as twist_instance_id")
    .distinct()
    .where("l.thread_id", "=", note.thread_id)
    .where("ti.archived_at", "is", null)
    .execute();
  for (const { twist_instance_id } of linkConnectors) {
    await notifyTwistSync(env, twist_instance_id, logger);
  }

  // Deferred compose: the thread was composed held with a create_link spec
  // and has no connector link yet — perform the dispatch skipped at compose
  // time. Only when this sweep just released the thread shell (a plain reply
  // in a thread with a stale stash must not re-compose).
  const composeSpec =
    releasedThread && linkConnectors.length === 0
      ? parsePendingCreateLink(releasedThread.pending_create_link)
      : null;
  if (composeSpec && releasedThread) {
    const contacts = await resolveCreateLinkContacts(
      db,
      authorUserId,
      (releasedThread.contacts ?? []) as string[],
      (releasedThread.groups ?? []) as string[],
      (error: unknown) => {
        logger.error(
          "expand_group_contacts failed during scheduled compose",
          error as Error,
          { thread_id: note.thread_id },
        );
      },
    );
    await dispatchCreateLink(env, ctx, db, {
      threadId: note.thread_id,
      twistInstanceId: composeSpec.twist_instance_id,
      draft: {
        channelId: composeSpec.channel_id ?? "",
        type: composeSpec.type,
        status: composeSpec.status,
        title: releasedThread.title ?? "",
        noteContent: note.content ?? null,
        contacts,
        inviteEmails: composeSpec.invite_emails ?? [],
        attachments: noteActionsToAttachments(note.actions),
      },
    });
  }

  // Unread + push fan-out. Scoped notes: the release UPDATE already fired the
  // trigger's scoped branch (per-user thread_state unread), so only push.
  // Unscoped notes: mark unread via the deterministic fallback, then push.
  let affectedUserIds: string[];
  if (isScopedNote(note.access_contacts, note.access_groups)) {
    affectedUserIds = await noteVisibleUserIds(
      db,
      note.thread_id,
      note.created_by,
      note.access_contacts,
      note.access_groups,
      authorUserId,
    );
  } else {
    affectedUserIds = await markThreadUnreadForOthers(
      env,
      db,
      note.thread_id,
      authorUserId,
      new Date().toISOString(),
    );
  }

  // The author's other devices need the released (send_at = NULL) state too.
  const notifyUserIds = [...new Set([...affectedUserIds, authorUserId])];
  for (const userId of notifyUserIds) {
    try {
      const userSyncId = env.USER_SYNC.idFromName(userId);
      const userSyncDO = env.USER_SYNC.get(userSyncId);
      await userSyncDO.fetch(
        new Request("http://do/notify", {
          method: "POST",
          body: JSON.stringify({ id: userId }),
        }),
      );
    } catch (error) {
      logger.error("Failed to notify UserSync for released note", error as Error, {
        user_id: userId,
        note_id: note.id,
      });
    }
  }
}

async function notifyTwistSync(
  env: Bindings,
  twistInstanceId: string,
  logger: ReturnType<typeof createLogger>,
): Promise<void> {
  try {
    const id = env.TWIST_SYNC.idFromName(twistInstanceId);
    const stub = env.TWIST_SYNC.get(id);
    await stub.fetch(
      new Request("http://do/notify", {
        method: "POST",
        body: JSON.stringify({ id: twistInstanceId }),
      }),
    );
  } catch (error) {
    logger.error("Failed to notify TwistSync for released note", error as Error, {
      twist_instance_id: twistInstanceId,
    });
  }
}
