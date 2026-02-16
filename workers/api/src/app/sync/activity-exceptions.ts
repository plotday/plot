import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { assertActivityAccess } from "./authorize";
import { parseReadParams } from "./helpers";
import { rpcUser } from "../../rpc";
import { notifySync, getPriorityForActivity } from "./notify";

const activityExceptions = new Hono<{ Bindings: Bindings }>();

// GET /sync/activity-exceptions
// Uses user.activity_exception view which filters by user access
activityExceptions.get("/sync/activity-exceptions", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince, cursorId, archived, limit, activityId, id, sortBy, sortDir } =
    parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.activity_exception")
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

// POST /sync/activity-exceptions - Upsert into activity_exception table
activityExceptions.post("/sync/activity-exceptions", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    await assertActivityAccess(trx, c.var.user.id, body.activity_id);
    return rpcUser(trx, "upsert_activity_exception", {
      user_id: c.var.user.id,
      p_id: body.id || null,
      p_activity_id: body.activity_id,
      p_occurrence: body.occurrence,
      p_archived_at: body.archived_at || null,
      p_updated_by: body.updated_by || 0,
      p_at: body.at || null,
      p_on: body.on || null,
      p_duration: body.duration || null,
      p_done_at: body.done_at || null,
      p_title: body.title || null,
      p_preview: body.preview || null,
      p_meta: body.meta || null,
    });
  });

  const priorityId = await getPriorityForActivity(c.var.db, body.activity_id);
  notifySync(c, priorityId);

  return c.json(result as any);
});

export default activityExceptions;
