import { Hono } from "hono";

import { sql, withUserDb, createDb } from "../../db";
import type { Bindings } from "../../env";
import { assertThreadAccess } from "./authorize";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { rpcUser } from "../../rpc";
import { notifySync, getPriorityForThread } from "./notify";

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

  // Generate embedding for search (best-effort, don't block the response)
  const noteId = (result as any)?.id ?? body.id;
  const content = body.content as string | null;
  if (noteId && content && content.trim().length > 0 && !body.draft) {
    c.executionCtx.waitUntil(
      (async () => {
        try {
          console.log("[embedding:sync] Generating embedding for note", noteId, "content length:", content.length);
          const response = (await c.env.AI.run("@cf/baai/bge-small-en-v1.5", {
            text: content,
          })) as { data: number[][] };
          console.log("[embedding:sync] Got embedding response", noteId, "dimensions:", response?.data?.[0]?.length);
          const embedding = response.data[0];
          const db = createDb(c.env);
          try {
            await db
              .updateTable("note")
              .set({ embedding: JSON.stringify(embedding) })
              .where("id", "=", noteId)
              .execute();
            console.log("[embedding:sync] Stored embedding for note", noteId);
          } finally {
            await db.destroy();
          }
        } catch (error) {
          console.error("[embedding:sync] Failed to generate embedding for note", noteId, error);
        }
      })()
    );
  } else {
    console.log("[embedding:sync] Skipping embedding", { noteId, hasContent: !!content, contentLength: content?.trim().length, draft: body.draft });
  }

  return c.json(result as any);
});

export default notes;
