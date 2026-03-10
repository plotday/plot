import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { getPriorityForThread, notifySync } from "./notify";
import { propagateLinkStatusTagsFromDb } from "./link-tags";

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
