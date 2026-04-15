import { Hono } from "hono";
import { PostHog } from "posthog-node";

import { createLogger } from "@plotday/worker-util";

import { type DB, type Kysely, createDb, sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { analyzeNote } from "../../queue/note-analysis";
import { rpc, rpcUser } from "../../rpc";
import {
  checkAiLimitForContacts,
  isAiEnabled,
  recordAiUsage,
} from "../../utils/ai-limits";
import { assertThreadAccess } from "./authorize";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { getPriorityForThread, notifySync } from "./notify";

const notes = new Hono<{ Bindings: Bindings }>();

// GET /sync/notes
notes.get("/sync/notes", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    archived,
    limit,
    threadId,
    id,
    sortBy,
    sortDir,
  } = parseReadParams(c);

  // On initial sync (epoch or no updated_since), a fresh client has nothing
  // to reconcile, so we skip the expensive redacted-stub query entirely.
  // On incremental sync, updated_since narrows the redacted branch so it's cheap.
  const isInitialSync =
    !updatedSince || updatedSince === "1970-01-01T00:00:00.000Z";

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    // Sort on the raw updated_at column so the planner can use
    // idx_note_updated_at. date_trunc() is still applied in the cursor
    // WHERE comparison to match JS Date millisecond precision.
    let visibleQ = trx
      .selectFrom("user.note")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);
    if (updatedSince) {
      visibleQ = visibleQ.orderBy("updated_at", "asc").orderBy("id", "asc");
      visibleQ = visibleQ.where(updatedSinceCursor(updatedSince, cursorId));
    } else {
      visibleQ = visibleQ.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }
    if (archived === true) visibleQ = visibleQ.where("archived_at", "is not", null);
    else if (archived === false) visibleQ = visibleQ.where("archived_at", "is", null);
    if (id) visibleQ = visibleQ.where("id", "=", id);
    if (threadId) visibleQ = visibleQ.where("thread_id", "=", threadId);

    const visible = await visibleQ.execute();
    if (isInitialSync) return visible;

    let redactedQ = trx
      .selectFrom("user.note_redacted")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);
    if (updatedSince) {
      redactedQ = redactedQ.orderBy("updated_at", "asc").orderBy("id", "asc");
      redactedQ = redactedQ.where(updatedSinceCursor(updatedSince, cursorId));
    } else {
      redactedQ = redactedQ.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }
    if (archived === true) redactedQ = redactedQ.where("archived_at", "is not", null);
    else if (archived === false) redactedQ = redactedQ.where("archived_at", "is", null);
    if (id) redactedQ = redactedQ.where("id", "=", id);
    if (threadId) redactedQ = redactedQ.where("thread_id", "=", threadId);

    const redacted = await redactedQ.execute();
    // Merge and re-sort to preserve the (updated_at, id) order across both
    // sets, then slice to the requested limit. Each server-side query is
    // already bounded by `limit`; the redacted set is typically tiny.
    const merged = [...visible, ...redacted];
    merged.sort((a, b) => {
      const au = a.updated_at ? a.updated_at.getTime() : 0;
      const bu = b.updated_at ? b.updated_at.getTime() : 0;
      if (au !== bu) return au - bu;
      const aid = a.id ?? "";
      const bid = b.id ?? "";
      return aid < bid ? -1 : aid > bid ? 1 : 0;
    });
    return merged.slice(0, limit);
  });

  // Enrich thread actions with current title and priorityId
  const threadIds = new Set<string>();
  for (const row of rows) {
    if (Array.isArray((row as any).actions)) {
      for (const action of (row as any).actions) {
        if (action.type === "thread" && action.threadId) {
          threadIds.add(action.threadId);
        }
      }
    }
  }

  if (threadIds.size > 0) {
    const threads = await withUserDb(c.var.db, userId, async (trx) =>
      trx
        .selectFrom("user.thread")
        .select(["id", "title", "priority_id"])
        .where("user_id", "=", userId)
        .where("id", "in", [...threadIds])
        .execute()
    );
    const threadMap = new Map(threads.map((t) => [t.id, t]));

    for (const row of rows) {
      if (Array.isArray((row as any).actions)) {
        for (const action of (row as any).actions) {
          if (action.type === "thread" && action.threadId) {
            const thread = threadMap.get(action.threadId);
            if (thread) {
              action.title = thread.title || "Untitled";
              action.priorityId = thread.priority_id;
            }
          }
        }
      }
    }
  }

  return c.json(rows as any);
});

// POST /sync/notes - Upsert into note table
notes.post("/sync/notes", async (c) => {
  const body = await c.req.json();

  // Check if this is an update (note already exists) before upserting.
  // We only run AI analysis on new notes — re-analyzing on edits causes
  // the AI to re-apply tags that users intentionally removed.
  const isUpdate = body.id
    ? !!(await c.var.db
        .selectFrom("note")
        .select("id")
        .where("id", "=", body.id)
        .executeTakeFirst())
    : false;

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    await assertThreadAccess(trx, c.var.user.id, body.thread_id);
    return rpcUser(trx, "upsert_note", {
      user_id: c.var.user.id,
      p_id: body.id || null,
      p_author_id: body.author_id,
      p_created_by: body.created_by || c.var.user.id,
      p_updated_by: body.updated_by || 0,
      p_archived_at: body.archived_at || null,
      p_thread_id: body.thread_id,
      p_draft: body.draft || false,
      p_access_contacts: (Array.isArray(body.access_contacts)
        ? `{${body.access_contacts.join(",")}}`
        : null) as any,
      p_content: body.content || null,
      p_actions: body.actions || null,
      p_mentions: (Array.isArray(body.mentions)
        ? `{${body.mentions.join(",")}}`
        : null) as any,
      p_re_note_id: body.re_note_id || null,
      p_source_created_at: body.source_created_at || null,
      p_key: body.key || null,
      p_merged_from_thread_id: body.merged_from_thread_id || null,
    });
  });

  const priorityId = await getPriorityForThread(c.var.db, body.thread_id, c.var.user.id);
  notifySync(c, priorityId);

  // Notify mentioned twists so they receive the onNoteCreated callback.
  // SyncNotify.notifyTwists() only notifies priority-owner twists, so
  // mention-based routing needs an explicit wake-up for any twist not
  // owned by the priority owner.
  if (Array.isArray(body.mentions) && body.mentions.length > 0 && !body.draft) {
    try {
      const accountTwists = await c.var.db
        .selectFrom("twist_instance")
        .select("id")
        .where("id", "in", body.mentions)
        .where("archived_at", "is", null)
        .execute();

      for (const twist of accountTwists) {
        const twistSyncId = c.env.TWIST_SYNC.idFromName(twist.id);
        const twistSyncDO = c.env.TWIST_SYNC.get(twistSyncId);
        c.executionCtx.waitUntil(
          twistSyncDO.fetch(
            new Request("http://do/notify", {
              method: "POST",
              body: JSON.stringify({ id: twist.id }),
            })
          )
        );
      }
    } catch (error) {
      const logger = createLogger({ operation: "notifyAccountTwists" });
      logger.error(
        "Error notifying account-level twist DOs",
        error as Error
      );
    }
  }

  // Background processing: AI analysis + unread marking (best-effort, don't block the response)
  // Uses its own DB connection since the request-scoped one is destroyed after the response
  // Only run for new notes — re-analyzing on edits causes the AI to re-apply removed tags
  const noteId = (result as any)?.id ?? body.id;
  const content = body.content as string | null;
  if (noteId && !body.draft && !body.archived_at && !isUpdate) {
    c.executionCtx.waitUntil(
      (async () => {
        const db = createDb(c.env);
        try {
          // 1. Generate embedding (independent of notification pipeline)
          let aiAllowed: {
            allowed: boolean;
            chargeUserId: string | null;
          } | null = null;
          if (content && content.trim().length > 0) {
            // Get all thread contacts + note access contacts to check limits against
            const thread = await db
              .selectFrom("thread")
              .select("contacts")
              .where("id", "=", body.thread_id)
              .executeTakeFirst();
            const contactIds = [
              ...new Set([
                ...(thread?.contacts ?? []),
                ...(body.access_contacts ?? []),
              ]),
            ];

            const [aiEnabled, aiLimit] = await Promise.all([
              isAiEnabled(db, c.var.user.id),
              checkAiLimitForContacts(
                c.env,
                db,
                contactIds,
                c.var.user.id,
                "note_processing"
              ),
            ]);

            if (aiEnabled && aiLimit.allowed) {
              aiAllowed = aiLimit;

              try {
                const response = (await c.env.AI.run(
                  "@cf/baai/bge-small-en-v1.5",
                  {
                    text: content,
                  }
                )) as { data: number[][] };
                const embedding = response.data[0];
                await db
                  .updateTable("note")
                  .set({ embedding: JSON.stringify(embedding) })
                  .where("id", "=", noteId)
                  .execute();
              } catch (error) {
                console.error(
                  "[embedding:sync] Failed to generate embedding for note",
                  noteId,
                  error
                );
              }
            }
          }

          // 2. Try AI analysis first — creates targeted unread rows respecting ignore/passive
          let analysisHandledUnread = false;
          if (aiAllowed) {
            const isRecent =
              !body.source_created_at ||
              Date.now() - new Date(body.source_created_at).getTime() <
                7 * 24 * 60 * 60 * 1000;
            if (isRecent) {
              try {
                analysisHandledUnread = await analyzeNote(
                  c.env,
                  noteId,
                  body.thread_id,
                  c.var.user.id
                );
              } catch (error) {
                const logger = createLogger({
                  operation: "sync:notes:analyzeNote",
                });
                logger.error("Failed to analyze note", error as Error, {
                  note_id: noteId,
                });
                c.var.tracker.captureException(error as Error);
              }
            }

            if (aiAllowed.chargeUserId) {
              recordAiUsage(c.env, aiAllowed.chargeUserId, "note_processing");
            }
          }

          // 3. Fallback: mark unread with default urgency if analysis didn't handle it
          let affectedUserIds: string[] = [];
          if (!analysisHandledUnread) {
            try {
              affectedUserIds = await markThreadUnreadForOthers(
                c.env,
                db,
                body.thread_id,
                c.var.user.id,
                new Date().toISOString()
              );
            } catch (error) {
              const logger = createLogger({
                operation: "sync:notes:markUnread",
              });
              logger.error(
                "Failed to mark thread unread for others",
                error as Error
              );
              c.var.tracker.captureException(error as Error);
            }
          } else {
            // Analysis handled unread — still need to collect user IDs for DO notification
            try {
              const thread = await db
                .selectFrom("thread")
                .select("contacts")
                .where("id", "=", body.thread_id)
                .executeTakeFirst();

              if (thread?.contacts && thread.contacts.length > 0) {
                const users = await db
                  .selectFrom("user_contact")
                  .select("user_id")
                  .where("contact_id", "in", thread.contacts as string[])
                  .where("linked", "=", true)
                  .where("archived_at", "is", null)
                  .execute();

                const userIds = [...new Set(users.map((u) => u.user_id))];
                affectedUserIds = userIds.filter((id) => id !== c.var.user.id);
              }
            } catch (error) {
              const logger = createLogger({ operation: "sync:notes:getUsers" });
              logger.error(
                "Failed to get thread users for DO notification",
                error as Error
              );
              c.var.tracker.captureException(error as Error);
            }
          }

          // 4. Notify UserSync DOs — triggers push notification pipeline
          for (const userId of affectedUserIds) {
            try {
              const userSyncId = c.env.USER_SYNC.idFromName(userId);
              const userSyncDO = c.env.USER_SYNC.get(userSyncId);
              await userSyncDO.fetch(
                new Request("http://do/notify", {
                  method: "POST",
                  body: JSON.stringify({ id: userId }),
                })
              );
            } catch (error) {
              const logger = createLogger({
                operation: "sync:notes:notifyUserSync",
              });
              logger.error(
                `Failed to notify UserSync for user ${userId}`,
                error as Error
              );
              c.var.tracker.captureException(error as Error);
            }
          }
        } finally {
          await db.destroy();
        }
      })()
    );
  }

  return c.json(result as any);
});

/**
 * Mark a thread as unread for all priority members except the excluded user.
 * Uses default urgency (inform-updates) — used as a fallback when AI analysis
 * doesn't run or fails.
 * Returns the list of user IDs that were successfully marked unread.
 */
export async function markThreadUnreadForOthers(
  env: Bindings,
  db: Kysely<DB>,
  threadId: string,
  excludeUserId: string,
  noteCreatedAt?: string
): Promise<string[]> {
  // Get all thread contacts
  const thread = await db
    .selectFrom("thread")
    .select("contacts")
    .where("id", "=", threadId)
    .executeTakeFirst();

  if (!thread?.contacts || thread.contacts.length === 0) return [];

  // Find all users linked to these contacts
  const users = await db
    .selectFrom("user_contact")
    .select("user_id")
    .where("contact_id", "in", thread.contacts as string[])
    .where("linked", "=", true)
    .where("archived_at", "is", null)
    .execute();

  const userIds = [...new Set(users.map((u) => u.user_id))];

  const markedUserIds: string[] = [];
  for (const userId of userIds) {
    if (userId === excludeUserId) continue;

    try {
      await rpcUser(db, "upsert_thread_unread", {
        user_id: userId,
        p_thread_id: threadId,
        p_urgency: "inform-updates",
        p_importance: 50,
        ...(noteCreatedAt ? { p_note_created_at: noteCreatedAt } : {}),
      });

      markedUserIds.push(userId);
    } catch (error) {
      const logger = createLogger({ operation: "markThreadUnreadForOthers" });
      logger.error(
        `Failed to mark thread unread for user ${userId}`,
        error as Error
      );
      const postHog = new PostHog(env.POSTHOG_API_KEY, {
        host: env.POSTHOG_HOST,
        flushAt: 1,
        flushInterval: 0,
      });
      postHog.captureException(error as Error, undefined, {
        context: "markThreadUnreadForOthers",
        user_id: userId,
        thread_id: threadId,
      });
      await postHog.shutdown();
    }
  }

  return markedUserIds;
}

export default notes;
