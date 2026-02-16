import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { parseReadParams } from "./helpers";
import { notifySync, getPriorityForActivity } from "./notify";

const activityTags = new Hono<{ Bindings: Bindings }>();

// GET /sync/activity-tags
activityTags.get("/sync/activity-tags", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    archived,
    limit,
    priorityPath,
    rangeStart,
    rangeEnd,
    sortBy,
    sortDir,
  } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.activity_tags")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    // Apply sort
    if (updatedSince) {
      query = query.orderBy("updated_at", "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    if (archived === true) {
      query = query.where("archived_at", "is not", null);
    } else if (archived === false) {
      query = query.where("archived_at", "is", null);
    }

    if (priorityPath) {
      query = query.where(
        sql<boolean>`priority_path <@ ${priorityPath}::ltree`
      );
    }

    // Composite cursor on (updated_at, id)
    if (updatedSince) {
      if (cursorId) {
        query = query.where(
          sql<boolean>`(updated_at > ${updatedSince}::timestamptz OR (updated_at = ${updatedSince}::timestamptz AND id > ${cursorId}))`
        );
      } else {
        query = query.where(sql<boolean>`updated_at > ${updatedSince}::timestamptz`);
      }
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

// POST /sync/activity-tags - Upsert into activity_tag table
activityTags.post("/sync/activity-tags", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_activity_tag", {
      user_id: c.var.user.id,
      p_actor_id: body.actor_id,
      p_activity_id: body.activity_id,
      p_occurrence: body.occurrence || null,
      p_tag_id: body.tag_id,
      p_updated_by: body.updated_by || 0,
      p_archived_at: body.archived_at || null,
    });
  });

  const priorityId = await getPriorityForActivity(c.var.db, body.activity_id);
  notifySync(c, priorityId);

  return c.json(result as any);
});

// POST /sync/activity-tags/update - Call update_activity_tags RPC
activityTags.post("/sync/activity-tags/update", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "update_activity_tags", {
      user_id: c.var.user.id,
      p_activity_id: body.activity_id,
      p_actor_id: body.actor_id,
      p_client_id: body.client_id,
      p_tag_updates: body.tag_updates,
      p_occurrence: body.occurrence || null,
    });
  });

  const priorityId2 = await getPriorityForActivity(c.var.db, body.activity_id);
  notifySync(c, priorityId2);

  return c.json(result as any);
});

export default activityTags;
