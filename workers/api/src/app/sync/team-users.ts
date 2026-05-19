import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import {
  parseReadParams,
  readSafeHorizon,
  seqEnvelope,
  seqSinceCursor,
} from "./helpers";

const teamUsers = new Hono<{ Bindings: Bindings }>();

// GET /sync/team-users — read-only, one row per team the user belongs to.
//
// team_user has no updated_at column so only seq-based cursors are supported.
// The view is already scoped to the requesting user via withUserDb, but we add
// an explicit user_id filter to match the pattern of other per-user endpoints.
teamUsers.get("/sync/team-users", async (c) => {
  const userId = c.var.user.id;
  const {
    seqSince,
    pageSeq,
    pageId,
    archived,
    limit,
  } = parseReadParams(c);

  const useSeqCursor = seqSince !== null;

  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    // Cast to any because user.team_user is not yet in the generated db-types.
    // Task 16 will run `pnpm types` to add it properly.
    let query = (trx as any)
      .selectFrom("user.team_user")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    if (useSeqCursor) {
      query = query
        .orderBy(sql`seq`, "asc")
        .orderBy("id", "asc")
        .where(seqSinceCursor(seqSince, pageSeq, pageId));
    } else {
      // No updated_at cursor support for team_user. Fall back to id ordering.
      query = query.orderBy("id", "asc");
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

export default teamUsers;
