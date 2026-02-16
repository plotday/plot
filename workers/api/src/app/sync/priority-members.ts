import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { assertPriorityAccess } from "./authorize";
import { parseReadParams } from "./helpers";
import { rpcUser } from "../../rpc";
import { notifySync } from "./notify";

const priorityMembers = new Hono<{ Bindings: Bindings }>();

// GET /sync/priority-members
// priority_member is a view; filter by priorities the user has access to
priorityMembers.get("/sync/priority-members", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince, cursorId, archived, limit, sortBy, sortDir } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("priority_member")
      .selectAll()
      .where(
        sql<boolean>`priority_id IN (SELECT priority_id FROM "user".priority_expanded WHERE user_id = ${userId})`
      )
      .limit(limit);

    // Apply sort
    if (updatedSince) {
      query = query.orderBy("updated_at", "asc").orderBy("contact_id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("contact_id", sortDir);
    }

    // Use composite cursor on (updated_at, contact_id)
    if (updatedSince) {
      if (cursorId) {
        query = query.where(
          sql<boolean>`(updated_at > ${updatedSince}::timestamptz OR (updated_at = ${updatedSince}::timestamptz AND contact_id > ${cursorId}))`
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

    return query.execute();
  });

  return c.json(rows as any);
});

// POST /sync/priority-members
priorityMembers.post("/sync/priority-members", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    await assertPriorityAccess(trx, userId, body.priority_id);
    // priority_member is a view backed by priority_contact + priority_user
    // Writes go to the underlying priority_contact table
    return rpcUser(trx, "upsert_priority_member", {
      user_id: userId,
      p_contact_id: body.contact_id,
      p_priority_id: body.priority_id,
      p_invited_by: body.invited_by || userId,
      p_invited_at: body.invited_at || null,
    });
  });

  notifySync(c, body.priority_id);

  return c.json(result as any);
});

export default priorityMembers;
