import { Hono } from "hono";

import { sql, withUserDb, createDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { twistFactory } from "../../twist/factory";
import {
  parseReadParams,
  readSafeHorizon,
  seqEnvelope,
  seqSinceCursor,
  updatedSinceCursor,
} from "./helpers";
import { unarchiveDoneLinksOnThread } from "./link-tags";
import { notifySync } from "./notify";

const schedules = new Hono<{ Bindings: Bindings }>();

// GET /sync/schedules
schedules.get("/sync/schedules", async (c) => {
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
    sortBy: _sortBy,
    sortDir,
  } = parseReadParams(c);
  const useSeqCursor = seqSince !== null;

  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.schedule" as any)
      .selectAll()
      .where("user_id", "=", userId);

    // Apply sort
    if (useSeqCursor) {
      query = query.orderBy("seq", "asc").orderBy("id", "asc");
    } else if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy("updated_at", sortDir).orderBy("id", sortDir);
    }

    query = query.limit(limit);

    // Single-row fetch by ID
    if (id) {
      query = query.where("id", "=", id);
    }

    // Cursor pagination
    if (useSeqCursor) {
      query = query.where(seqSinceCursor(seqSince, pageSeq, pageId));
    } else if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId));
    }

    // Archived filter
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

// POST /sync/schedules - Upsert via upsert_schedule() RPC
schedules.post("/sync/schedules", async (c) => {
  const body = await c.req.json();
  const schedule = body.schedule || body;
  const contacts = schedule.contacts || body.contacts;

  // Reject updates to link schedules — only sources can modify those
  const linkId = schedule.link_id || body.defaults?.link_id;
  if (linkId) {
    return c.json({ error: "Cannot modify link schedules via sync" }, 403);
  }
  if (schedule.id && !schedule.link_id && !schedule.thread_id) {
    // Updating by ID only — check if it's a link schedule
    const existing = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
      return trx
        .selectFrom("schedule" as any)
        .select("link_id")
        .where("id", "=", schedule.id)
        .executeTakeFirst();
    });
    if (existing?.link_id) {
      return c.json({ error: "Cannot modify link schedules via sync" }, 403);
    }
  }

  // Capture pre-upsert activeness so we can detect a transition from
  // inactive → active below (only in that case should we unarchive the
  // thread). Without this, any re-save of an already-active user schedule
  // — including the implicit push triggered when Thread.save() runs while
  // _userSchedule is non-null — unarchives the thread the user just archived.
  const preUpsertId = schedule?.id as string | undefined;
  const preUpsert = preUpsertId
    ? await (c.var.db as any)
        .selectFrom("schedule")
        .select(["user_id", "archived_at", "on", "at"])
        .where("id", "=", preUpsertId)
        .executeTakeFirst()
    : undefined;
  const preWasActiveUserSchedule =
    preUpsert?.user_id != null &&
    preUpsert.archived_at == null &&
    (preUpsert.on != null || preUpsert.at != null);

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    const scheduleResult = await rpcUser(trx, "upsert_schedule", {
      user_id: c.var.user.id,
      p_schedule: schedule as any,
      p_defaults: (body.defaults || {}) as any,
    });

    // Process contacts if provided (already resolved to contact_id by the client)
    if (contacts && Array.isArray(contacts) && contacts.length > 0) {
      await rpcUser(trx, "upsert_schedule_contacts", {
        user_id: c.var.user.id,
        p_schedule_id: (scheduleResult as any).id,
        p_contacts: contacts,
      });
    }

    return scheduleResult;
  });

  // Resolve the thread this schedule is attached to, then:
  //   1. notifySync to wake priority-bound twists (SyncNotify → TwistSync DOs)
  //   2. Direct dispatch to connector's onThreadToDo for source twists
  //      (connectors don't declare Plot tool, so the view-based Plot dispatch
  //      can't reach them — mirror the /sync/links pattern and call
  //      Integrations.dispatch directly).
  //   3. Lift archived_at on the thread when an active user schedule is
  //      upserted, so adding to the agenda also unarchives.
  const scheduleId = (result as any)?.id as string | undefined;
  if (scheduleId) {
    const updated = await (c.var.db as any)
      .selectFrom("schedule")
      .select(["thread_id", "link_id", "user_id", "on", "at", "archived_at"])
      .where("id", "=", scheduleId)
      .executeTakeFirst();

    let threadId: string | null = updated?.thread_id ?? null;
    if (!threadId && updated?.link_id) {
      const link = await (c.var.db as any)
        .selectFrom("link")
        .select("thread_id")
        .where("id", "=", updated.link_id)
        .executeTakeFirst();
      threadId = link?.thread_id ?? null;
    }

    // Adding a thread to the agenda should lift archive state so the user
    // sees it where they expect to act. Only clears archive when this upsert
    // transitions the user schedule from inactive → active — not on every
    // no-op re-save. Thread.save() pushes _userSchedule unconditionally when
    // it's non-null, so archiving a thread with outstanding tasks otherwise
    // fires this path and re-unarchives the thread.
    const isActiveUserSchedule =
      updated?.user_id != null &&
      updated.archived_at == null &&
      (updated.on != null || updated.at != null);
    const justBecameActive = isActiveUserSchedule && !preWasActiveUserSchedule;
    if (threadId && justBecameActive) {
      await (c.var.db as any)
        .updateTable("thread")
        .set({ archived_at: null })
        .where("id", "=", threadId)
        .where("archived_at", "is not", null)
        .execute();

      // Also flip any done-status links back to a non-done status so the
      // link widget no longer shows "Archived" and Tag.Done is cleared.
      try {
        await unarchiveDoneLinksOnThread(c.var.db as any, threadId);
      } catch (error) {
        console.error("[sync/schedules] unarchiveDoneLinksOnThread failed:", error);
      }
    }

    if (threadId) {
      const thread = await (c.var.db as any)
        .selectFrom("thread")
        .select(["created_by"])
        .where("id", "=", threadId)
        .executeTakeFirst();

      const tp = await (c.var.db as any)
        .selectFrom("thread_priority")
        .select("priority_id")
        .where("thread_id", "=", threadId)
        .where("user_id", "=", c.var.user.id)
        .executeTakeFirst();

      if (tp?.priority_id) {
        notifySync(c, tp.priority_id);
      }

      // Direct dispatch to the connector that owns the thread, if any.
      // Matches the /sync/links direct-dispatch pattern so user-originated
      // agenda toggles reach onThreadToDo without waiting for TwistSync polling.
      if (thread?.created_by && tp?.priority_id) {
        const createdBy = thread.created_by as string;
        const scheduleItem = {
          ...updated,
          id: scheduleId,
          thread_id: threadId,
        };
        c.executionCtx.waitUntil(
          (async () => {
            const db = createDb(c.env);
            try {
              // Check if created_by is a connector (has channel rows)
              const isConnector = await (db as any)
                .selectFrom("channel")
                .select("twist_instance_id")
                .where("twist_instance_id", "=", createdBy)
                .limit(1)
                .executeTakeFirst();
              if (!isConnector) return;

              const factory = twistFactory({
                env: c.env,
                ctx: c.executionCtx as any,
                db,
              });

              const twistWrapper = await factory({
                twistInstanceId: createdBy,
              });

              await twistWrapper.dispatch("Integrations", {
                itemType: "thread_schedule" as const,
                item: scheduleItem,
              });
            } catch (error) {
              console.error("[sync/schedules] Direct connector dispatch failed:", error);
            } finally {
              await db.destroy();
            }
          })()
        );
      }
    }
  }

  return c.json(result as any);
});

// POST /sync/schedule/status - Update current user's RSVP status on a schedule
schedules.post("/sync/schedule/status", async (c) => {
  const body = await c.req.json();
  const { schedule_id, thread_id, occurrence, status } = body;

  if (!schedule_id && !thread_id) {
    return c.json({ error: "schedule_id or thread_id is required" }, 400);
  }

  // Resolve the target schedule_id from thread_id + optional occurrence
  let targetScheduleId = schedule_id;

  if (thread_id && !schedule_id) {
    targetScheduleId = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
      // Schedules attach to threads either directly (schedule.thread_id) or
      // via a link (schedule.link_id → link.thread_id). Match both so this
      // endpoint works for link schedules (e.g. Google Calendar events).
      const threadFilter = sql<boolean>`(schedule.thread_id = ${thread_id}::uuid OR schedule.link_id IN (SELECT id FROM link WHERE thread_id = ${thread_id}::uuid))`;

      if (occurrence) {
        // Per-occurrence: find existing occurrence schedule or create one
        const existing = await trx
          .selectFrom("schedule" as any)
          .select("id")
          .where(threadFilter)
          .where("occurrence", "=", occurrence)
          .executeTakeFirst();

        if (existing) return existing.id;

        // Copy the base schedule and create an occurrence-specific row
        const base = await trx
          .selectFrom("schedule" as any)
          .selectAll()
          .where(threadFilter)
          .where("occurrence", "is", null)
          .executeTakeFirst();

        if (!base) return null;

        const newId = crypto.randomUUID();
        await trx
          .insertInto("schedule" as any)
          .values({
            id: newId,
            thread_id: base.thread_id,
            link_id: base.link_id,
            occurrence: occurrence,
            start_at: base.start_at,
            end_at: base.end_at,
            start_on: base.start_on,
            end_on: base.end_on,
            recurrence_rule: base.recurrence_rule,
            recurrence_exdates: base.recurrence_exdates,
          })
          .execute();

        // Copy contacts from base schedule to the new occurrence schedule
        const baseContacts = await trx
          .selectFrom("schedule_contact" as any)
          .selectAll()
          .where("schedule_id", "=", base.id)
          .execute();

        for (const contact of baseContacts) {
          await trx
            .insertInto("schedule_contact" as any)
            .values({
              schedule_id: newId,
              contact_id: contact.contact_id,
              status: contact.status,
              role: contact.role,
            })
            .execute();
        }

        return newId;
      } else {
        // Series-level: find the base schedule
        const base = await trx
          .selectFrom("schedule" as any)
          .select("id")
          .where(threadFilter)
          .where("occurrence", "is", null)
          .executeTakeFirst();
        return base?.id ?? null;
      }
    });
  }

  if (!targetScheduleId) {
    return c.json({ error: "Schedule not found" }, 404);
  }

  await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    await rpcUser(trx, "update_schedule_contact_status", {
      user_id: c.var.user.id,
      p_schedule_id: targetScheduleId,
      p_status: status ?? null,
    });
  });

  // Look up the priority_id for the schedule to trigger source notification
  const schedule = await c.var.db
    .selectFrom("schedule")
    .select(["thread_id", "link_id"])
    .where("id", "=", targetScheduleId)
    .executeTakeFirst();

  if (schedule) {
    // Resolve thread_id from either direct or via link
    const threadId = schedule.thread_id ?? (schedule.link_id
      ? (await c.var.db.selectFrom("link").select("thread_id").where("id", "=", schedule.link_id).executeTakeFirst())?.thread_id
      : null);
    if (threadId) {
      const tp = await c.var.db
        .selectFrom("thread_priority")
        .select("priority_id")
        .where("thread_id", "=", threadId)
        .where("user_id", "=", c.var.user.id)
        .executeTakeFirst();
      if (tp?.priority_id) {
        notifySync(c, tp.priority_id);
      }
    }

    // Notify the twist that created the link directly for the
    // onScheduleContactUpdated callback. Link-authoring twists (connectors)
    // would otherwise miss this notification.
    if (schedule.link_id) {
      const sourceTwists = await c.var.db
        .selectFrom("twist_instance as pt")
        .innerJoin("link as l", "l.created_by", "pt.id")
        .select("pt.id")
        .where("l.id", "=", schedule.link_id)
        .where("pt.archived_at", "is", null)
        .execute();

      for (const twist of sourceTwists) {
        const twistSyncId = c.env.TWIST_SYNC.idFromName(twist.id);
        const twistSyncDO = c.env.TWIST_SYNC.get(twistSyncId);
        c.executionCtx.waitUntil(
          twistSyncDO
            .fetch(
              new Request("http://do/notify", {
                method: "POST",
                body: JSON.stringify({ id: twist.id }),
              })
            )
            .catch(() => {})
        );
      }
    }
  }

  return c.json({ ok: true });
});

export default schedules;
