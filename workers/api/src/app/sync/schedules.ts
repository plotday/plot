import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { notifySync } from "./notify";

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

  // Reject updates to link schedules — only sources can modify those
  const linkId = schedule.link_id || body.defaults?.link_id;
  if (linkId) {
    return c.json({ error: "Cannot modify link schedules via sync" }, 403);
  }
  if (schedule.id && !schedule.link_id && !schedule.thread_id) {
    // Updating by ID only — check if it's a link schedule
    const existing = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
      return trx
        .selectFrom("schedule" as any)
        .select("link_id")
        .where("id", "=", schedule.id)
        .executeTakeFirst();
    });
    if (existing?.link_id) {
      return c.json({ error: "Cannot modify link schedules via sync" }, 403);
    }
  }

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

// POST /sync/schedule/status - Update current user's RSVP status on a schedule
schedules.post("/sync/schedule/status", async (c) => {
  const body = await c.req.json();
  const { schedule_id, status } = body;

  if (!schedule_id) {
    return c.json({ error: "schedule_id is required" }, 400);
  }

  await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    await rpcUser(trx, "update_schedule_contact_status", {
      user_id: c.var.user.id,
      p_schedule_id: schedule_id,
      p_status: status ?? null,
    });
  });

  // Look up the priority_id for the schedule to trigger source notification
  const schedule = await c.var.db
    .selectFrom("schedule")
    .select(["thread_id", "link_id"])
    .where("id", "=", schedule_id)
    .executeTakeFirst();

  if (schedule) {
    let priorityId: string | null = null;
    if (schedule.thread_id) {
      const thread = await c.var.db
        .selectFrom("thread")
        .select("priority_id")
        .where("id", "=", schedule.thread_id)
        .executeTakeFirst();
      priorityId = thread?.priority_id ?? null;
    } else if (schedule.link_id) {
      const link = await c.var.db
        .selectFrom("link")
        .innerJoin("thread", "thread.id", "link.thread_id")
        .select("thread.priority_id")
        .where("link.id", "=", schedule.link_id)
        .executeTakeFirst();
      priorityId = link?.priority_id ?? null;
    }
    if (priorityId) {
      notifySync(c, priorityId);
    }
  }

  return c.json({ ok: true });
});

export default schedules;
