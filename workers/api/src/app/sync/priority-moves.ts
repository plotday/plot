import { Hono } from "hono";
import { createLogger } from "@plotday/worker-util";

import { sql, withFrontendDb, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import {
  enqueueJobs,
  logClassificationDecision,
} from "../../state/classify-thread";
import { notifyUserSyncByEnv } from "./notify";

const priorityMoves = new Hono<{ Bindings: Bindings }>();

// POST /sync/priority-moves — record an explicit user move of a thread into a
// priority. Sets thread_priority.user_moved = TRUE (the training flag used by
// classify_thread_for_user) and schedules a retroactive re-filing pass over
// the user's other threads.
//
// The priority_id itself is already kept in sync via the normal thread save
// path (upsert_thread). This endpoint only owns the user_moved flag and the
// async reclassify side-effect.
priorityMoves.post("/sync/priority-moves", async (c) => {
  const body = await c.req.json();
  const userId = c.var.user.id;
  const logger = createLogger({ component: "sync-priority-moves" });

  const threadId = body.thread_id as string | undefined;
  const priorityId = body.priority_id as string | undefined;

  if (!threadId || !priorityId) {
    return c.json({ error: "thread_id and priority_id are required" }, 400);
  }

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    const updated = await sql<{ thread_id: string }>`
      INSERT INTO public.thread_priority (thread_id, user_id, priority_id, user_moved, applied_default_channel_id)
      VALUES (${threadId}::uuid, ${userId}::uuid, ${priorityId}::uuid, TRUE, NULL)
      ON CONFLICT (thread_id, user_id) DO UPDATE
        SET priority_id = EXCLUDED.priority_id,
            user_moved = TRUE,
            -- Explicit user move is not a default placement. Clear the
            -- marker so apply_channel_default does not later pull this row
            -- back when the channel default changes.
            applied_default_channel_id = NULL,
            -- The move settles the placement at the user's choice. Clear any
            -- pending classify marker so the row doesn't strand: the classify
            -- worker skips user_moved rows, so a classify_at left set here would
            -- be re-enqueued by the hourly sweep forever (the user_moved leak).
            classify_at = NULL,
            archived_at = NULL,
            updated_at = now()
      RETURNING thread_id
    `.execute(trx);

    // Decision history: record the correction so an earlier auto-decision
    // with a different priority becomes a labeled misclassification.
    await logClassificationDecision(trx, c.env, {
      threadId,
      userId,
      priorityId,
      stage: "user_move",
      scores: {},
      classifier: "user",
    });

    return { thread_id: updated.rows[0]?.thread_id ?? threadId };
  });

  // Kick off retroactive re-filing after the response. Runs bounded
  // (p_max_candidates = 500) and guards user_moved = TRUE rows internally.
  // Notify the user's sync DO so reassigned thread_priority rows reach the
  // live app without a restart.
  c.executionCtx.waitUntil(
    (async () => {
      try {
        // c.var.db is destroyed by dbMiddleware once the response returns, so
        // post-response work must spin up its own short-lived Kysely.
        await withFrontendDb(c.env, async (db) => {
          const marked = await sql<{ user_id: string; thread_id: string }>`
            SELECT user_id::text AS user_id, thread_id::text AS thread_id
              FROM public.mark_reclassify_candidates(
                ${userId}::uuid, ${threadId}::uuid)
          `.execute(db);
          await enqueueJobs(
            c.env,
            marked.rows.map((r) => ({
              userId: r.user_id,
              threadId: r.thread_id,
            }))
          );
          await notifyUserSyncByEnv(c.env, userId);
        });
      } catch (error) {
        logger.error("Retroactive reclassify failed", error as Error, {
          user_id: userId,
          thread_id: threadId,
        });
        c.var.tracker.captureException(error as Error);
      }
    })()
  );

  return c.json(result);
});

export default priorityMoves;
