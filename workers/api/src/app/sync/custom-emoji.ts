import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import {
  parseReadParams,
  readSafeHorizon,
  seqEnvelope,
} from "./helpers";

const customEmoji = new Hono<{ Bindings: Bindings }>();

// GET /sync/custom-emoji
//
// Read-only endpoint exposing the workspace's cached custom emoji
// (provider:workspaceId/name → image_url). Writes are server-side only:
// connectors populate this table when they discover new emoji on their
// platforms (e.g. Slack `emoji.list`, Google Chat custom emoji
// references). Clients render reactions whose emoji string matches a
// custom_emoji.id by fetching image_url.
//
// Scoped per-user only insofar as workspaces are; for v1 we return all
// rows the API can see, since the table is a small platform-wide cache
// and clients don't need filtering until tenancy lands here.
customEmoji.get("/sync/custom-emoji", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    seqSince,
    pageSeq,
    pageId,
    archived,
    limit,
  } = parseReadParams(c);

  const useSeqCursor = seqSince !== null;

  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    // Typed as any because Kysely's builder unionizes across the many
    // conditional `query = query.where(...)` reassignments below; the
    // `as any` cast on the table name keeps TS2590 from firing inside
    // selectFrom's overload resolution.
    let query: any = trx
      .selectFrom("custom_emoji" as any)
      .selectAll()
      .limit(limit);

    if (useSeqCursor) {
      query = query.where(sql<boolean>`seq >= ${seqSince}::xid8`);
      query = query.where(sql<boolean>`seq < pg_snapshot_xmin(pg_current_snapshot())`);
      if (pageSeq && pageId) {
        query = query.where(
          sql<boolean>`(seq, id) > (${pageSeq}::xid8, ${pageId})`,
        );
      } else if (pageSeq) {
        query = query.where(sql<boolean>`seq > ${pageSeq}::xid8`);
      }
      query = query.orderBy("seq", "asc").orderBy("id", "asc");
    } else if (updatedSince) {
      query = query
        .orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc")
        .orderBy("id", "asc");
      if (cursorId) {
        query = query.where(
          sql<boolean>`(date_trunc('milliseconds', updated_at) > ${updatedSince}::timestamptz OR (date_trunc('milliseconds', updated_at) = ${updatedSince}::timestamptz AND id > ${cursorId}))`,
        );
      } else {
        query = query.where(
          sql<boolean>`date_trunc('milliseconds', updated_at) > ${updatedSince}::timestamptz`,
        );
      }
    } else {
      query = query.orderBy("updated_at", "desc").orderBy("id", "desc");
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

export default customEmoji;
