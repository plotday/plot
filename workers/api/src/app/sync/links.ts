import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { getPriorityForThread, notifySync } from "./notify";
import { propagateLinkStatusTagsFromDb } from "./link-tags";
import { createSchedule } from "./smart-schedule";

const links = new Hono<{ Bindings: Bindings }>();

// GET /sync/links
links.get("/sync/links", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    limit,
    id,
    sortBy,
    sortDir,
    priorityId,
    priorityPath,
    rangeStart,
    rangeEnd,
  } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.link" as any)
      .selectAll()
      .where("user_id", "=", userId);

    // Apply sort
    if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
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

    // Priority filter (same pattern as threads)
    if (priorityId) {
      query = query.where(
        sql<boolean>`priority_id IN (SELECT child_id FROM priority_child WHERE priority_id = ${priorityId}::uuid)`
      );
    } else if (priorityPath) {
      query = query.where(
        sql<boolean>`priority_path <@ ${priorityPath}::ltree`
      );
    }

    // Range filtering on updated_at (scalar)
    if (rangeStart) {
      query = query.where(sql<boolean>`${sql.ref(sortBy)} > ${rangeStart}::timestamptz`);
    }
    if (rangeEnd) {
      query = query.where(sql<boolean>`${sql.ref(sortBy)} < ${rangeEnd}::timestamptz`);
    }

    return query.execute();
  });

  return c.json(rows as any);
});

// POST /sync/links - Upsert via upsert_link() RPC
links.post("/sync/links", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_link", {
      user_id: c.var.user.id,
      p_link: (body.link || body) as any,
      p_defaults: (body.defaults || {}) as any,
    });
  });

  // Propagate status tags if the link has a thread and status was included
  const linkData = body.link || body;
  if (result.thread_id && linkData.status !== undefined) {
    try {
      await propagateLinkStatusTagsFromDb(c.var.db, result);
    } catch {
      // Non-critical: tag propagation failure shouldn't break the sync
    }
  }

  // Create task schedule when link is assigned to a user
  const assigneeId = result.assignee_id;
  const linkThreadId = result.thread_id;
  if (assigneeId && linkThreadId) {
    c.executionCtx.waitUntil(
      (async () => {
        try {
          const contact = await c.var.db
            .selectFrom("contact")
            .select("user_id")
            .where("id", "=", assigneeId)
            .executeTakeFirst();
          if (!contact?.user_id) return;

          await createSchedule(c.var.db, contact.user_id, linkThreadId, 'task');
          // Recompute outstanding_tasks for the assignee
          await sql`SELECT recompute_outstanding_tasks(${linkThreadId}::uuid, ${contact.user_id}::uuid)`.execute(c.var.db);
        } catch (error) {
          console.error("[schedule] Failed to create task schedule from link assignment:", error);
        }
      })()
    );
  }

  // Recompute outstanding_tasks when link status changes (may mark done/undone)
  if (linkThreadId && linkData.status !== undefined) {
    c.executionCtx.waitUntil(
      (async () => {
        try {
          if (assigneeId) {
            // Recompute for the assigned user
            const contact = await c.var.db
              .selectFrom("contact")
              .select("user_id")
              .where("id", "=", assigneeId)
              .executeTakeFirst();
            if (contact?.user_id) {
              await sql`SELECT recompute_outstanding_tasks(${linkThreadId}::uuid, ${contact.user_id}::uuid)`.execute(c.var.db);
            }
          } else {
            // Unassigned link: recompute for all users with a schedule on this thread
            const schedules = await c.var.db
              .selectFrom("schedule")
              .select("user_id")
              .where("thread_id", "=", linkThreadId)
              .where("user_id", "is not", null)
              .where("occurrence", "is", null)
              .execute();
            for (const sched of schedules) {
              if (sched.user_id) {
                await sql`SELECT recompute_outstanding_tasks(${linkThreadId}::uuid, ${sched.user_id}::uuid)`.execute(c.var.db);
              }
            }
          }
        } catch (error) {
          console.error("[schedule] Failed to recompute outstanding_tasks from link status:", error);
        }
      })()
    );
  }

  // Notify sync so twist callbacks (e.g. onLinkUpdated) can fire
  if (linkData.thread_id) {
    try {
      const priorityId = await getPriorityForThread(c.var.db, linkData.thread_id);
      notifySync(c, priorityId);
    } catch {
      // Thread lookup may fail for orphaned links
    }
  } else if (linkData.priority_id) {
    // Threadless links have priority_id directly
    notifySync(c, linkData.priority_id);
  }

  return c.json(result as any);
});

export default links;
