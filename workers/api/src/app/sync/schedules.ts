import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { parseReadParams, updatedSinceCursor } from "./helpers";

const schedules = new Hono<{ Bindings: Bindings }>();

// GET /sync/schedules
schedules.get("/sync/schedules", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    archived,
    limit,
    id,
    sortBy,
    sortDir,
  } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.schedule" as any)
      .selectAll()
      .where("user_id", "=", userId);

    // Apply sort
    if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy("updated_at", sortDir).orderBy("id", sortDir);
    }

    query = query.limit(limit);

    // Single-row fetch by ID
    if (id) {
      query = query.where("id", "=", id);
    }

    // Cursor pagination
    if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId));
    }

    // Archived filter
    if (archived === true) {
      query = query.where("archived_at", "is not", null);
    } else if (archived === false) {
      query = query.where("archived_at", "is", null);
    }

    return query.execute();
  });

  return c.json(rows as any);
});

// POST /sync/schedules - Upsert via upsert_schedule() RPC
schedules.post("/sync/schedules", async (c) => {
  const body = await c.req.json();
  const schedule = body.schedule || body;
  const contacts = schedule.contacts || body.contacts;

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    const scheduleResult = await rpcUser(trx, "upsert_schedule", {
      user_id: c.var.user.id,
      p_schedule: schedule as any,
      p_defaults: (body.defaults || {}) as any,
    });

    // Process contacts if provided (already resolved to contact_id by the client)
    if (contacts && Array.isArray(contacts) && contacts.length > 0) {
      await rpcUser(trx, "upsert_schedule_contacts", {
        user_id: c.var.user.id,
        p_schedule_id: (scheduleResult as any).id,
        p_contacts: contacts,
      });
    }

    return scheduleResult;
  });

  return c.json(result as any);
});

export default schedules;
