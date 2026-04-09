import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { notifySync, getPriorityForNote } from "./notify";
import { createSchedule } from "./smart-schedule";
import { stripCountTagActors } from "./viewer";

const noteTags = new Hono<{ Bindings: Bindings }>();

// GET /sync/note-tags
noteTags.get("/sync/note-tags", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    archived,
    limit,
    priorityId,
    priorityPath,
    rangeStart,
    rangeEnd,
    sortBy,
    sortDir,
  } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.note_tags" as any)
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    // Apply sort
    if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    if (archived === true) {
      query = query.where("archived_at", "is not", null);
    } else if (archived === false) {
      query = query.where("archived_at", "is", null);
    }

    // Priority filter: prefer ID-based lookup, fall back to path for backward compatibility
    if (priorityId) {
      query = query.where(
        sql<boolean>`priority_id IN (SELECT child_id FROM priority_child WHERE priority_id = ${priorityId}::uuid)`
      );
    } else if (priorityPath) {
      query = query.where(
        sql<boolean>`priority_path <@ ${priorityPath}::ltree`
      );
    }

    // Composite cursor on (updated_at, id)
    if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId));
    }

    // Calendar range filter
    if (rangeStart || rangeEnd) {
      const start = rangeStart || "";
      const end = rangeEnd || "";
      const tstzRange = `[${start},${end})`;
      const dateStart = rangeStart ? rangeStart.split("T")[0] : "";
      const dateEnd = rangeEnd ? rangeEnd.split("T")[0] : "";
      const dateRange = `[${dateStart},${dateEnd})`;
      query = query.where(
        sql<boolean>`(range_at && ${tstzRange}::tstzrange OR range_on && ${dateRange}::daterange)`
      );
    }

    return query.execute();
  });

  await stripCountTagActors(c.var.db, userId, rows as any, "note", c.var.apiVersion ?? 0);

  return c.json(rows as any);
});

// POST /sync/note-tags - Upsert into note_tag table
noteTags.post("/sync/note-tags", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_note_tag", {
      user_id: c.var.user.id,
      p_actor_id: body.actor_id,
      p_note_id: body.note_id,
      p_tag_id: body.tag_id,
      p_updated_by: body.updated_by || 0,
      p_archived_at: body.archived_at || null,
    });
  });

  const priorityId = await getPriorityForNote(c.var.db, body.note_id);
  notifySync(c, priorityId);

  // Create task schedule when todo tag is added
  if (body.tag_id === 1 && !body.archived_at) {
    try {
      const contact = await c.var.db
        .selectFrom("contact")
        .select("user_id")
        .where("id", "=", body.actor_id)
        .executeTakeFirst();

      if (contact?.user_id) {
        const note = await c.var.db
          .selectFrom("note")
          .select("thread_id")
          .where("id", "=", body.note_id)
          .executeTakeFirst();

        if (note?.thread_id) {
          await createSchedule(c.var.db, contact.user_id, note.thread_id, 'task');
          // Recompute outstanding_tasks on the per-user schedule
          await sql`SELECT recompute_outstanding_tasks(${note.thread_id}::uuid, ${contact.user_id}::uuid)`.execute(c.var.db);
        }
      }
    } catch (error) {
      console.error("[schedule] Failed to create task schedule from note tag:", error);
    }
  }

  // Recompute outstanding_tasks when todo tag is removed (archived) or done tag is added
  if ((body.tag_id === 1 && body.archived_at) || body.tag_id === 3) {
    try {
      const contact = await c.var.db
        .selectFrom("contact")
        .select("user_id")
        .where("id", "=", body.actor_id)
        .executeTakeFirst();

      if (contact?.user_id) {
        const note = await c.var.db
          .selectFrom("note")
          .select("thread_id")
          .where("id", "=", body.note_id)
          .executeTakeFirst();

        if (note?.thread_id) {
          await sql`SELECT recompute_outstanding_tasks(${note.thread_id}::uuid, ${contact.user_id}::uuid)`.execute(c.var.db);
        }
      }
    } catch (error) {
      console.error("[schedule] Failed to recompute outstanding_tasks from note tag:", error);
    }
  }

  return c.json(result as any);
});

// POST /sync/note-tags/update - Call update_note_tags RPC
noteTags.post("/sync/note-tags/update", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "update_note_tags", {
      user_id: c.var.user.id,
      p_note_id: body.note_id,
      p_actor_id: body.actor_id,
      p_client_id: body.client_id,
      p_tag_updates: body.tag_updates,
    });
  });

  const priorityId2 = await getPriorityForNote(c.var.db, body.note_id);
  notifySync(c, priorityId2);

  // Create task schedule when todo tags are added via update
  if (body.tag_updates) {
    const todoEntries = Object.entries(body.tag_updates as Record<string, boolean>)
      .filter(([key, val]) => val === true && key.startsWith('1:'));

    if (todoEntries.length > 0) {
      try {
        const note = await c.var.db
          .selectFrom("note")
          .select("thread_id")
          .where("id", "=", body.note_id)
          .executeTakeFirst();

        if (note?.thread_id) {
          for (const [key] of todoEntries) {
            const actorId = key.split(':')[1];
            const contact = await c.var.db
              .selectFrom("contact")
              .select("user_id")
              .where("id", "=", actorId)
              .executeTakeFirst();
            if (!contact?.user_id) continue;
            await createSchedule(c.var.db, contact.user_id, note.thread_id, 'task');
            // Recompute outstanding_tasks
            await sql`SELECT recompute_outstanding_tasks(${note.thread_id}::uuid, ${contact.user_id}::uuid)`.execute(c.var.db);
          }
        }
      } catch (error) {
        console.error("[schedule] Failed to create task schedule from tag update:", error);
      }
    }

    // Recompute outstanding_tasks for todo removals and done tag changes
    const recomputeEntries = Object.entries(body.tag_updates as Record<string, boolean>)
      .filter(([key, val]) =>
        (key.startsWith('1:') && val === false) || // todo removed
        key.startsWith('3:') // done tag added/removed
      );

    if (recomputeEntries.length > 0) {
      try {
        const note = await c.var.db
          .selectFrom("note")
          .select("thread_id")
          .where("id", "=", body.note_id)
          .executeTakeFirst();

        if (note?.thread_id) {
          for (const [key] of recomputeEntries) {
            const actorId = key.split(':')[1];
            const contact = await c.var.db
              .selectFrom("contact")
              .select("user_id")
              .where("id", "=", actorId)
              .executeTakeFirst();
            if (!contact?.user_id) continue;
            await sql`SELECT recompute_outstanding_tasks(${note.thread_id}::uuid, ${contact.user_id}::uuid)`.execute(c.var.db);
          }
        }
      } catch (error) {
        console.error("[schedule] Failed to recompute outstanding_tasks from tag update:", error);
      }
    }
  }

  return c.json(result as any);
});

export default noteTags;
