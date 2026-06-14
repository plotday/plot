import { Hono } from "hono";

import { mapPgError, sql, withUserDb, createDb } from "../../db";
import type { Bindings } from "../../env";
import {
  parseReadParams,
  readSafeHorizon,
  seqEnvelope,
  seqSinceCursor,
  updatedSinceCursor,
} from "./helpers";
import { rpcUser } from "../../rpc";
import { enqueueChannelRouter } from "../../state/channel-router";
import { notifySync, notifyUserSync } from "./notify";
import { deriveFacetFilters } from "../../state/derive-facet-filters";

const priorities = new Hono<{ Bindings: Bindings }>();

// Project a user.priority row for the wire. All clients are now on the flat
// focus model (apiVersion >= 4): a flat list of focuses with no nesting. The
// per-user root is labelled "Inbox"; every other focus uses its own `title`
// verbatim.
//
// IMPORTANT: never substitute a derived/ancestry value into `title`. The
// client stores whatever it receives as `title` and re-sends it on the next
// save, and upsert_priority writes it straight back into priority.title. A
// previous version projected an ancestry breadcrumb ("Plot › Marketing") into
// `title`, which the client round-tripped — baking the breadcrumb into the
// stored title and making renames appear to revert. `title` must stay the
// raw, user-editable leaf name. (`flat_title` has been removed from the view.)
export function projectPriority(row: any, apiVersion: number) {
  // Defensive: tolerate a stale view that still carries flat_title during a
  // deploy window — strip it so it never reaches the client as data.
  const { flat_title: _flat, ...rest } = row;
  if (apiVersion < 5) {
    // is_fyi is a v5 concept; pre-v5 clients don't model the column, so strip
    // it and let the FYI focus appear as an ordinary focus.
    const { is_fyi: _fyi, ...preV5 } = rest;
    if (apiVersion < 4) return preV5;
    return { ...preV5, title: row.root ? "Inbox" : row.title };
  }
  return { ...rest, title: row.root ? "Inbox" : row.title };
}

// GET /sync/priorities
priorities.get("/sync/priorities", async (c) => {
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
      .selectFrom("user.priority")
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

    if (id) { query = query.where("id", "=", id); }
    const fetchedRows = await query.execute();
    const horizonValue = useSeqCursor ? await readSafeHorizon(trx) : "0";
    return { rows: fetchedRows, horizon: horizonValue };
  });

  // Flat (apiVersion >= 4) clients render priorities as a flat list of
  // "focuses" with no nesting; the per-user root is labelled "Inbox". See
  // projectPriority for why `title` must never carry a derived value.
  const apiVersion = c.var.apiVersion ?? 0;
  const outRows = rows.map((row) => projectPriority(row, apiVersion));

  if (useSeqCursor) {
    return c.json(seqEnvelope(outRows as any, limit, horizon) as any);
  }
  return c.json(outRows as any);
});

// POST /sync/priorities - Upsert via the user.priority view (INSTEAD OF trigger)
priorities.post("/sync/priorities", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    return rpcUser(trx, "upsert_priority", {
      user_id: userId,
      p_priority: body,
    });
  });

  notifySync(c, body.id);

  // In the per-user priority model, priorities are single-owner — no
  // displaced users to notify on move.
  const displacedUsers: { user_id: string }[] = [];
  for (const row of displacedUsers) {
    notifyUserSync(c, row.user_id);
  }

  // Any priority mutation — create, rename, archive — can shift which
  // channel should default to which priority. Enqueue a debounced router
  // run. Safe to fire-and-forget; the DO coalesces repeated calls.
  c.executionCtx.waitUntil(
    enqueueChannelRouter(c.env, userId).catch(() => {
      // Router enqueue failures are non-fatal for the priority upsert.
    })
  );

  // Derive facet filters for the focus from its title + description (LLM, in
  // the background so it never blocks the upsert). Skip archived focuses.
  const title = typeof body.title === "string" ? body.title.trim() : "";
  const priorityId = typeof body.id === "string" ? body.id : null;
  const description = typeof body.description === "string" ? body.description : null;
  const isArchived = body.archived_at != null;
  if (priorityId && title && !isArchived) {
    const tracker = c.var.tracker;
    c.executionCtx.waitUntil(
      (async () => {
        const db = createDb(c.env);
        try {
          const filters = await deriveFacetFilters(c.env, title, description);
          if (filters !== null) {
            await db
              .updateTable("priority")
              .set({ facet_filters: filters as any })
              .where("id", "=", priorityId)
              .where("user_id", "=", userId)
              .execute();
          }
        } catch (error) {
          tracker.captureException(error as Error);
        } finally {
          await db.destroy();
        }
      })()
    );
  }

  return c.json(result as any);
});

// POST /sync/priorities/merge — merge one focus into another server-side.
//
// Re-files every thread_priority row from the source onto the target in a
// single statement and archives the source (user.merge_priority). This
// replaces the client-side per-thread re-file loop: each of those saves went
// through POST /sync/threads, which treated it as a first-time explicit
// filing (user_moved flip + retroactive mark_reclassify_candidates sweep), so
// merging a focus mass-reclassified the user's whole workspace. A bulk merge
// is a deliberate re-file, not N classifier-training events — no training
// signal or reclassify sweep fires here.
priorities.post("/sync/priorities/merge", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();
  const sourceId = body.source_priority_id;
  const targetId = body.target_priority_id;
  if (typeof sourceId !== "string" || typeof targetId !== "string") {
    return c.json(
      { error: "source_priority_id and target_priority_id are required" },
      400,
    );
  }

  try {
    const moved = await withUserDb(c.var.db, userId, async (trx) => {
      return rpcUser(trx, "merge_priority", {
        user_id: userId,
        p_source_priority_id: sourceId,
        p_target_priority_id: targetId,
      });
    });

    // Wake the user's other devices: the source focus archived and the
    // re-filed threads both flow through the normal sync cursors.
    notifySync(c, sourceId);

    // Archiving the source can shift which channel defaults to which focus.
    c.executionCtx.waitUntil(
      enqueueChannelRouter(c.env, userId).catch(() => {
        // Router enqueue failures are non-fatal for the merge.
      })
    );

    return c.json({ moved: moved as number });
  } catch (e) {
    // Expected RAISEs from user.merge_priority (self-merge, unknown or
    // archived focus) → 4xx; anything else propagates to the global handler.
    const mapped = mapPgError(e);
    if (mapped) {
      return c.json({ error: mapped.message }, mapped.status as 400 | 403 | 409 | 422);
    }
    throw e;
  }
});

export default priorities;
