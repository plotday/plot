import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { parseReadParams } from "./helpers";
import { notifySync } from "./notify";

const activities = new Hono<{ Bindings: Bindings }>();

// GET /sync/activities
activities.get("/sync/activities", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    archived,
    limit,
    priorityPath,
    rangeStart,
    rangeEnd,
    initial,
    id,
    sortBy,
    sortDir,
  } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.activity")
      .selectAll()
      .where("user_id", "=", userId);

    // Apply sort: use custom sort when not doing cursor pagination
    if (updatedSince) {
      query = query.orderBy("updated_at", "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    // Don't apply limit for initial pulls
    if (!initial) {
      query = query.limit(limit);
    }

    // Single-row fetch by ID
    if (id) {
      query = query.where("id", "=", id);
    }

    // Cursor pagination
    if (updatedSince) {
      if (cursorId) {
        query = query.where(
          sql<boolean>`(updated_at > ${updatedSince}::timestamptz OR (updated_at = ${updatedSince}::timestamptz AND id > ${cursorId}))`
        );
      } else {
        query = query.where(sql<boolean>`updated_at > ${updatedSince}::timestamptz`);
      }
    }

    // Initial pull: fetch active OR unread activities (skip archived filter)
    if (initial && archived !== true) {
      const now = new Date().toISOString();
      const today = now.split("T")[0];
      query = query.where(
        sql<boolean>`(
          (type = 'action' AND done_at IS NULL AND archived_at IS NULL AND (
            range_at && ${`(,${now})`}::tstzrange OR
            range_on && ${`(,${today})`}::daterange OR
            (range_at IS NULL AND range_on IS NULL)
          ))
          OR (unread = true AND archived_at IS NULL AND draft = false)
        )`
      );
    } else {
      // Archived filter (only when not initial)
      if (archived === true) {
        query = query.where("archived_at", "is not", null);
      } else if (archived === false) {
        query = query.where("archived_at", "is", null);
      }
    }

    // Priority path filter
    if (priorityPath) {
      query = query.where(
        sql<boolean>`priority_path <@ ${priorityPath}::ltree`
      );
    }

    // Calendar range filter: match either timestamp range or date range
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

// POST /sync/activities - Upsert via upsert_activity() RPC
activities.post("/sync/activities", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_activity", {
      user_id: c.var.user.id,
      p_activity: (body.activity || body) as any,
      p_defaults: (body.defaults || {}) as any,
    });
  });

  const activityData = body.activity || body;
  notifySync(c, activityData.priority_id);

  return c.json(result as any);
});

export default activities;
