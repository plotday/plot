import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { notifySync, getPriorityForNote } from "./notify";

const noteTags = new Hono<{ Bindings: Bindings }>();

// GET /sync/note-tags
noteTags.get("/sync/note-tags", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    archived,
    limit,
    priorityId,
    priorityPath,
    rangeStart,
    rangeEnd,
    sortBy,
    sortDir,
  } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.note_tags")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    // Apply sort
    if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    if (archived === true) {
      query = query.where("archived_at", "is not", null);
    } else if (archived === false) {
      query = query.where("archived_at", "is", null);
    }

    // Priority filter: prefer ID-based lookup, fall back to path for backward compatibility
    if (priorityId) {
      query = query.where(
        sql<boolean>`priority_id IN (SELECT child_id FROM priority_child WHERE priority_id = ${priorityId}::uuid)`
      );
    } else if (priorityPath) {
      query = query.where(
        sql<boolean>`priority_path <@ ${priorityPath}::ltree`
      );
    }

    // Composite cursor on (updated_at, id)
    if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId));
    }

    // Calendar range filter
    if (rangeStart || rangeEnd) {
      const start = rangeStart || "";
      const end = rangeEnd || "";
      const tstzRange = `[${start},${end})`;
      const dateStart = rangeStart ? rangeStart.split("T")[0] : "";
      const dateEnd = rangeEnd ? rangeEnd.split("T")[0] : "";
      const dateRange = `[${dateStart},${dateEnd})`;
      query = query.where(
        sql<boolean>`(range_at && ${tstzRange}::tstzrange OR range_on && ${dateRange}::daterange)`
      );
    }

    return query.execute();
  });

  return c.json(rows as any);
});

// POST /sync/note-tags - Upsert into note_tag table
noteTags.post("/sync/note-tags", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_note_tag", {
      user_id: c.var.user.id,
      p_actor_id: body.actor_id,
      p_note_id: body.note_id,
      p_tag_id: body.tag_id,
      p_updated_by: body.updated_by || 0,
      p_archived_at: body.archived_at || null,
    });
  });

  const priorityId = await getPriorityForNote(c.var.db, body.note_id);
  notifySync(c, priorityId);

  return c.json(result as any);
});

// POST /sync/note-tags/update - Call update_note_tags RPC
noteTags.post("/sync/note-tags/update", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "update_note_tags", {
      user_id: c.var.user.id,
      p_note_id: body.note_id,
      p_actor_id: body.actor_id,
      p_client_id: body.client_id,
      p_tag_updates: body.tag_updates,
    });
  });

  const priorityId2 = await getPriorityForNote(c.var.db, body.note_id);
  notifySync(c, priorityId2);

  return c.json(result as any);
});

export default noteTags;
