import { Hono } from "hono";

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

  // Background processing: unread marking + AI analysis (best-effort, don't block the response)
  // Uses its own DB connection since the request-scoped one is destroyed after the response
  const noteId = (result as any)?.id ?? body.id;
  const content = body.content as string | null;
  if (noteId && !body.draft && !body.archived_at) {
    c.executionCtx.waitUntil(
      (async () => {
        const db = createDb(c.env);
        try {
          // 1. ALWAYS mark thread unread for other priority members
          try {
            const markedUserIds = await markThreadUnreadForOthers(db, priorityId, body.thread_id, c.var.user.id);
            // Notify each affected user's UserSync DO directly — bypasses SyncNotify
            // debounce, which would swallow the second call if the first alarm hasn't fired yet
            for (const userId of markedUserIds) {
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
          } catch (error) {
            const logger = createLogger({ operation: "sync:notes:markUnread" });
            logger.error("Failed to mark thread unread for others", error as Error);
            c.var.tracker.captureException(error as Error);
          }

          // 2. AI analysis (optional — upgrades urgency/importance if it runs)
          if (!content || content.trim().length === 0) return;

          // Check ai_enabled setting and free-tier limits before running AI
          const [aiEnabled, aiAllowed] = await Promise.all([
            isAiEnabled(db, c.var.user.id),
            checkAiLimitForPriority(c.env, db, priorityId, c.var.user.id, "note_processing"),
          ]);

          if (!aiEnabled) {
            console.log("[embedding:sync] AI disabled for user, skipping", noteId);
            return;
          }

          if (!aiAllowed.allowed) {
            console.log("[embedding:sync] AI limit reached for all priority members, skipping", noteId);
            return;
          }

          // Generate embedding
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

          // AI note analysis for auto-tagging
          const isRecent = !body.source_created_at ||
            (Date.now() - new Date(body.source_created_at).getTime()) < 7 * 24 * 60 * 60 * 1000;
          if (isRecent) {
            try {
              await analyzeNote(c.env, noteId, body.thread_id, c.var.user.id);
            } catch (error) {
              console.error("[note-analysis] Failed to analyze note", noteId, error);
            }
          }

          // Record usage against the user whose quota was checked
          recordAiUsage(c.env, aiAllowed.chargeUserId, "note_processing");
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
 * Mark a thread as unread for all priority members except the syncing user.
 * Uses default urgency — AI analysis upgrades this later via upsert if it runs.
 * Returns the list of user IDs that were successfully marked unread.
 */
async function markThreadUnreadForOthers(
  db: Kysely<DB>,
  priorityId: string,
  threadId: string,
  syncingUserId: string
): Promise<string[]> {
  // rpc() unwraps single-column TABLE results, so we get string[] (user IDs) directly
  // TypeScript still thinks these are { user_id: string } from generated types, but runtime is string
  const usersData = await rpc(db, "get_users_with_priority_access", {
    target_priority_id: priorityId,
  });
  const userIds = (!usersData ? [] : Array.isArray(usersData) ? usersData : [usersData]) as unknown as string[];

  const markedUserIds: string[] = [];
  for (const userId of userIds) {
    if (userId === syncingUserId) continue;

    try {
      await rpcUser(db, "upsert_thread_unread", {
        user_id: userId,
        p_thread_id: threadId,
        p_urgency: "inform-updates",
        p_importance: 50,
      });

      markedUserIds.push(userId);
    } catch (error) {
      console.error(`Failed to mark thread unread for user ${userId}:`, error);
    }
  }

  return markedUserIds;
}

export default notes;
