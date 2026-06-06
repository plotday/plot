// /sync/topics. apiVersion < 3 = legacy compat (serves the user.group shape as
// "topics" for old clients — unchanged). apiVersion >= 3 = the new topic ENTITY
// feed (user.topic), mirroring /sync/groups (seq + updatedSince cursors).
//
// NOTE (Plan 3 Task 7, DEFERRED): topic-entity access-loss cleanup
// (user.topic_redacted merge) is not yet wired. The >= 3 feed queries
// user.topic only (forward path). When Task 7 lands, add the redacted merge
// here exactly like sync/notes.ts does for user.note + user.note_redacted.
import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import {
  parseReadParams,
  readSafeHorizon,
  seqEnvelope,
  seqSinceCursor,
  updatedSinceCursor,
} from "./helpers";

const topics = new Hono<{ Bindings: Bindings }>();

topics.get("/sync/topics", async (c) => {
  const userId = c.var.user.id;
  const apiVersion = c.var.apiVersion ?? 0;
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

  // Legacy (apiVersion < 3): serve user.group, updatedSince cursor only.
  if (apiVersion < 3) {
    const rows = await withUserDb(c.var.db, userId, async (trx) => {
      let query = trx
        .selectFrom("user.group")
        .selectAll()
        .where("user_id", "=", userId)
        .limit(limit);

      if (updatedSince) {
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

      return query.execute();
    });
    return c.json(rows as any);
  }

  // apiVersion >= 3: new topic entity feed (user.topic), seq + updatedSince.
  const useSeqCursor = seqSince !== null;
  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.topic")
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

    const fetchedRows = await query.execute();
    const horizonValue = useSeqCursor ? await readSafeHorizon(trx) : "0";
    return { rows: fetchedRows, horizon: horizonValue };
  });

  if (useSeqCursor) {
    return c.json(seqEnvelope(rows as any, limit, horizon) as any);
  }
  return c.json(rows as any);
});

export default topics;
