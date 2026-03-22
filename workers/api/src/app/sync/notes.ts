import { Hono } from "hono";
import { PostHog } from "posthog-node";

import { sql, withUserDb, createDb, type DB, type Kysely } from "../../db";
import type { Bindings } from "../../env";
import { assertThreadAccess } from "./authorize";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { rpc, rpcUser } from "../../rpc";
import { notifySync, getPriorityForThread } from "./notify";
import { analyzeNote } from "../../queue/note-analysis";
import { checkAiLimitForPriority, recordAiUsage, isAiEnabled } from "../../utils/ai-limits";
import { createLogger } from "@plotday/worker-util";

const notes = new Hono<{ Bindings: Bindings }>();

// GET /sync/notes
notes.get("/sync/notes", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince, cursorId, archived, limit, threadId, id, sortBy, sortDir } =
    parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.note")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    // Apply sort
    if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId));
    }

    if (archived === true) {
      query = query.where("archived_at", "is not", null);
    } else if (archived === false) {
      query = query.where("archived_at", "is", null);
    }

    if (id) { query = query.where("id", "=", id); }
    if (threadId) {
      query = query.where("thread_id", "=", threadId);
    }

    return query.execute();
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
      p_private: body.private || false,
      p_content: body.content || null,
      p_actions: body.actions || null,
      p_mentions: (Array.isArray(body.mentions) ? `{${body.mentions.join(",")}}` : null) as any,
      p_re_note_id: body.re_note_id || null,
      p_source_created_at: body.source_created_at || null,
      p_key: body.key || null,
      p_merged_from_thread_id: body.merged_from_thread_id || null,
    });
  });

  const priorityId = await getPriorityForThread(c.var.db, body.thread_id);
  notifySync(c, priorityId);

  // Background processing: AI analysis + unread marking (best-effort, don't block the response)
  // Uses its own DB connection since the request-scoped one is destroyed after the response
  const noteId = (result as any)?.id ?? body.id;
  const content = body.content as string | null;
  if (noteId && !body.draft && !body.archived_at) {
    c.executionCtx.waitUntil(
      (async () => {
        const db = createDb(c.env);
        try {
          // 1. Generate embedding (independent of notification pipeline)
          let aiAllowed: { allowed: boolean; chargeUserId: string | null } | null = null;
          if (content && content.trim().length > 0) {
            const [aiEnabled, aiLimit] = await Promise.all([
              isAiEnabled(db, c.var.user.id),
              checkAiLimitForPriority(c.env, db, priorityId, c.var.user.id, "note_processing"),
            ]);

            if (aiEnabled && aiLimit.allowed) {
              aiAllowed = aiLimit;

              try {
                console.log("[embedding:sync] Generating embedding for note", noteId, "content length:", content.length);
                const response = (await c.env.AI.run("@cf/baai/bge-small-en-v1.5", {
                  text: content,
                })) as { data: number[][] };
                console.log("[embedding:sync] Got embedding response", noteId, "dimensions:", response?.data?.[0]?.length);
                const embedding = response.data[0];
                await db
                  .updateTable("note")
                  .set({ embedding: JSON.stringify(embedding) })
                  .where("id", "=", noteId)
                  .execute();
                console.log("[embedding:sync] Stored embedding for note", noteId);
              } catch (error) {
                console.error("[embedding:sync] Failed to generate embedding for note", noteId, error);
              }
            } else if (!aiEnabled) {
              console.log("[embedding:sync] AI disabled for user, skipping", noteId);
            } else {
              console.log("[embedding:sync] AI limit reached for all priority members, skipping", noteId);
            }
          }

          // 2. Try AI analysis first — creates targeted unread rows respecting ignore/passive
          let analysisHandledUnread = false;
          if (aiAllowed) {
            const isRecent = !body.source_created_at ||
              (Date.now() - new Date(body.source_created_at).getTime()) < 7 * 24 * 60 * 60 * 1000;
            if (isRecent) {
              try {
                analysisHandledUnread = await analyzeNote(c.env, noteId, body.thread_id, c.var.user.id);
              } catch (error) {
                const logger = createLogger({ operation: "sync:notes:analyzeNote" });
                logger.error("Failed to analyze note", error as Error, { note_id: noteId });
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
              affectedUserIds = await markThreadUnreadForOthers(c.env, db, priorityId, body.thread_id, c.var.user.id);
            } catch (error) {
              const logger = createLogger({ operation: "sync:notes:markUnread" });
              logger.error("Failed to mark thread unread for others", error as Error);
              c.var.tracker.captureException(error as Error);
            }
          } else {
            // Analysis handled unread — still need to collect user IDs for DO notification
            try {
              const usersData = await rpc(db, "get_users_with_priority_access", {
                target_priority_id: priorityId,
              });
              const userIds = (!usersData ? [] : Array.isArray(usersData) ? usersData : [usersData]) as unknown as string[];
              affectedUserIds = userIds.filter(id => id !== c.var.user.id);
            } catch (error) {
              const logger = createLogger({ operation: "sync:notes:getUsers" });
              logger.error("Failed to get priority users for DO notification", error as Error);
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
              const logger = createLogger({ operation: "sync:notes:notifyUserSync" });
              logger.error(`Failed to notify UserSync for user ${userId}`, error as Error);
              c.var.tracker.captureException(error as Error);
            }
          }
        } finally {
          await db.destroy();
        }
      })()
    );
  } else if (noteId) {
    console.log("[embedding:sync] Skipping background processing", { noteId, hasContent: !!content, contentLength: content?.trim().length, draft: body.draft, archived: !!body.archived_at });
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
  priorityId: string,
  threadId: string,
  excludeUserId: string
): Promise<string[]> {
  // rpc() unwraps single-column TABLE results, so we get string[] (user IDs) directly
  // TypeScript still thinks these are { user_id: string } from generated types, but runtime is string
  const usersData = await rpc(db, "get_users_with_priority_access", {
    target_priority_id: priorityId,
  });
  const userIds = (!usersData ? [] : Array.isArray(usersData) ? usersData : [usersData]) as unknown as string[];

  const markedUserIds: string[] = [];
  for (const userId of userIds) {
    if (userId === excludeUserId) continue;

    try {
      await rpcUser(db, "upsert_thread_unread", {
        user_id: userId,
        p_thread_id: threadId,
        p_urgency: "inform-updates",
        p_importance: 50,
      });

      markedUserIds.push(userId);
    } catch (error) {
      const logger = createLogger({ operation: "markThreadUnreadForOthers" });
      logger.error(`Failed to mark thread unread for user ${userId}`, error as Error);
      const postHog = new PostHog(env.POSTHOG_API_KEY, { host: env.POSTHOG_HOST, flushAt: 1, flushInterval: 0 });
      postHog.captureException(error as Error, undefined, { context: "markThreadUnreadForOthers", user_id: userId, thread_id: threadId });
      await postHog.shutdown();
    }
  }

  return markedUserIds;
}

export default notes;
