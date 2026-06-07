import { Hono } from "hono";

import { mapPgError, sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import {
  parseReadParams,
  readSafeHorizon,
  seqEnvelope,
  seqSinceCursor,
  updatedSinceCursor,
} from "./helpers";
import { notifyUserSync } from "./notify";

const groups = new Hono<{ Bindings: Bindings }>();

groups.get("/sync/groups", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    seqSince,
    pageSeq,
    pageId,
    archived,
    limit,
    sortBy,
    sortDir,
  } = parseReadParams(c);

  const useSeqCursor = seqSince !== null;

  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.group")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    if (useSeqCursor) {
      query = query.orderBy("seq", "asc").orderBy("id", "asc")
        .where(seqSinceCursor(seqSince, pageSeq, pageId));
    } else if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc")
        .where(updatedSinceCursor(updatedSince, cursorId));
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    if (archived === true) {
      query = query.where("archived_at", "is not", null);
    } else if (archived === false) {
      query = query.where("archived_at", "is", null);
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

// POST /sync/groups - Create or update a group from a single client row.
// Body: { id, name?, privacy?, member_contact_ids? }. The server diffs the row
// (create on a new id; rename admin-only; membership diff for roster-visible
// callers). Returns { id }.
groups.post("/sync/groups", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  if (!body.id) {
    return c.json({ error: "id is required" }, 400);
  }

  try {
    const groupId = await withUserDb(c.var.db, userId, async (trx) => {
      return rpcUser(trx, "save_group", {
        user_id: userId,
        p_group: {
          id: body.id,
          name: body.name ?? null,
          privacy: body.privacy ?? null,
          member_contact_ids: body.member_contact_ids ?? [],
        },
      });
    });

    notifyUserSync(c, userId);
    return c.json({ id: groupId } as any);
  } catch (e) {
    const mapped = mapPgError(e);
    if (mapped) {
      return c.json({ error: mapped.message }, mapped.status as 400 | 403 | 409 | 422);
    }
    throw e;
  }
});

export default groups;
