import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { assertActivityAccess } from "./authorize";
import { parseReadParams } from "./helpers";
import { rpcUser } from "../../rpc";
import { notifySync, getPriorityForActivity } from "./notify";

const notes = new Hono<{ Bindings: Bindings }>();

// GET /sync/notes
notes.get("/sync/notes", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince, cursorId, archived, limit, activityId, id, sortBy, sortDir } =
    parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.note")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    // Apply sort
    if (updatedSince) {
      query = query.orderBy("updated_at", "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    if (updatedSince) {
      if (cursorId) {
        query = query.where(
          sql<boolean>`(updated_at > ${updatedSince}::timestamptz OR (updated_at = ${updatedSince}::timestamptz AND id > ${cursorId}))`
        );
      } else {
        query = query.where(sql<boolean>`updated_at > ${updatedSince}::timestamptz`);
      }
    }

    if (archived === true) {
      query = query.where("archived_at", "is not", null);
    } else if (archived === false) {
      query = query.where("archived_at", "is", null);
    }

    if (id) { query = query.where("id", "=", id); }
    if (activityId) {
      query = query.where("activity_id", "=", activityId);
    }

    return query.execute();
  });

  return c.json(rows as any);
});

// POST /sync/notes - Upsert into note table
notes.post("/sync/notes", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    await assertActivityAccess(trx, c.var.user.id, body.activity_id);
    return rpcUser(trx, "upsert_note", {
      user_id: c.var.user.id,
      p_id: body.id || null,
      p_author_id: body.author_id,
      p_created_by: body.created_by || c.var.user.id,
      p_updated_by: body.updated_by || 0,
      p_archived_at: body.archived_at || null,
      p_activity_id: body.activity_id,
      p_draft: body.draft || false,
      p_private: body.private || false,
      p_content: body.content || null,
      p_links: body.links || null,
      p_mentions: (Array.isArray(body.mentions) ? `{${body.mentions.join(",")}}` : null) as any,
      p_re_note_id: body.re_note_id || null,
      p_source_created_at: body.source_created_at || null,
      p_key: body.key || null,
    });
  });

  const priorityId = await getPriorityForActivity(c.var.db, body.activity_id);
  notifySync(c, priorityId);

  return c.json(result as any);
});

export default notes;
