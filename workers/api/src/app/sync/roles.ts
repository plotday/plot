import { Hono } from "hono";

import { mapPgError, sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import {
  parseReadParams,
  readSafeHorizon,
  seqEnvelope,
  seqSinceCursor,
  updatedSinceCursor,
} from "./helpers";
import { rpcUser } from "../../rpc";
import { notifyUserSync } from "./notify";

const roles = new Hono<{ Bindings: Bindings }>();

// GET /sync/roles — incremental seq/updatedSince cursor over user.role.
roles.get("/sync/roles", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    seqSince,
    pageSeq,
    pageId,
    archived,
    limit,
    id,
    sortBy,
    sortDir,
  } = parseReadParams(c);
  const useSeqCursor = seqSince !== null;

  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.role")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    if (useSeqCursor) {
      query = query
        .orderBy("seq", "asc")
        .orderBy("id", "asc")
        .where(seqSinceCursor(seqSince, pageSeq, pageId));
    } else if (updatedSince) {
      query = query
        .orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc")
        .orderBy("id", "asc")
        .where(updatedSinceCursor(updatedSince, cursorId));
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    if (archived === true) {
      query = query.where("archived_at", "is not", null);
    } else if (archived === false) {
      query = query.where("archived_at", "is", null);
    }

    if (id) {
      query = query.where("id", "=", id);
    }

    const fetchedRows = await query.execute();
    const horizonValue = useSeqCursor ? await readSafeHorizon(trx) : "0";
    return { rows: fetchedRows, horizon: horizonValue };
  });

  if (useSeqCursor) {
    return c.json(seqEnvelope(rows as any, limit, horizon) as any);
  }
  return c.json(rows as any);
});

// POST /sync/roles — upsert a role (auto-creates its Inbox on first insert;
// archive-only-when-empty + never-the-last-role guards live in upsert_role).
roles.post("/sync/roles", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  try {
    const result = await withUserDb(c.var.db, userId, async (trx) =>
      rpcUser(trx, "upsert_role", { user_id: userId, p_role: body }),
    );

    // upsert_role RETURNS the role id (it generates one via uuidv7() when the
    // client POSTs a new role without an `id`); we still surface it in the
    // response below.
    const roleId =
      typeof result === "string"
        ? result
        : typeof body.id === "string"
          ? body.id
          : undefined;

    // Roles are user-scoped (one owner per row), so notify the owner's
    // UserSync DO directly. The priority-scoped `notifySync(priorityId)`
    // resolves recipients via `get_users_with_priority_access`, which finds
    // no users for a role id — so the broadcast never reached other devices.
    notifyUserSync(c, userId);

    // Return an object, not the bare id string. The Flutter client pushes
    // roles via `api.post<Map<String, dynamic>>('/sync/roles', …)` and casts
    // the decoded body to a Map; a JSON string decodes to a Dart String and
    // the cast throws, stranding the row in sync. Mirror POST /sync/groups,
    // which returns `{ id }`.
    return c.json({ id: roleId } as any);
  } catch (e) {
    // Expected RAISEs from upsert_role (role_not_empty, role_last) → 4xx;
    // anything else propagates to the global handler.
    const mapped = mapPgError(e);
    if (mapped) {
      return c.json(
        { error: mapped.message },
        mapped.status as 400 | 403 | 409 | 422,
      );
    }
    c.var.tracker.captureException(e as Error);
    throw e;
  }
});

export default roles;
