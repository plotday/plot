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

const actors = new Hono<{ Bindings: Bindings }>();

// GET /sync/actors - Read-only
actors.get("/sync/actors", async (c) => {
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
      .selectFrom("user.actor")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    // Apply sort
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

// POST /sync/actors - Add or rename a contact in the user's address book.
// Only type==="contact" rows are writable (twist-instance actors are read-only).
// Body: { id, type, email?, name? }. Returns the canonical user.actor row so the
// client can reconcile its optimistic id with the server-owned (email-keyed) id.
actors.post("/sync/actors", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  if (body.type !== "contact") {
    return c.json({ error: "Only contacts can be saved" }, 400);
  }
  if (!body.id) {
    return c.json({ error: "id is required" }, 400);
  }

  try {
    const result = await withUserDb(c.var.db, userId, async (trx) => {
      return rpcUser(trx, "save_user_contact", {
        user_id: userId,
        p_contact_id: body.id,
        p_email: body.email ?? null,
        p_name: body.name ?? null,
      });
    });

    notifyUserSync(c, userId);
    return c.json(result as any);
  } catch (e) {
    // A RAISE EXCEPTION from the function surfaces as a Postgres error. Treat
    // these as client errors so the offline queue reverts the optimistic row
    // instead of retrying forever.
    const mapped = mapPgError(e);
    if (mapped) {
      return c.json({ error: mapped.message }, mapped.status as 400 | 403 | 409 | 422);
    }
    throw e;
  }
});

export default actors;
