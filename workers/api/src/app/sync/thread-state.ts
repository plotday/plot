import { Hono } from "hono";

import { mapPgError } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { notifySync, notifyUserSync, getPriorityForThread } from "./notify";

const threadState = new Hono<{ Bindings: Bindings }>();

// POST /sync/thread-state - Write per-user thread_state.
//
// Body fields (all optional unless noted):
//   - thread_id (required)
//   - read_at      → mark read (calls clear_thread_state; race-safe)
//   - active       → boolean (Doing section in the unified feed)
//   - task         → boolean (task list — typically set by connectors)
//   - to_read      → boolean (reading list)
//   - urgent       → boolean
//   - importance   → 0..100
//   - order        → drag-to-reorder position within Doing / Scheduled
//   - on           → "[date,date)" daterange — per-user "do on this date"
//   - at           → "[ts,ts)"   tstzrange  — per-user "do at this time"
//   - bumped_at    → user "bump to top" timestamp
//
// `read_at` is processed via clear_thread_state (which preserves an existing
// read marker on a stale upsert). All other fields are processed via
// upsert_thread_state with explicit p_set_* flags so the caller can update
// a single field without clobbering the rest.
threadState.post("/sync/thread-state", async (c) => {
  const body = await c.req.json();
  const userId = c.var.user.id;
  const records = Array.isArray(body) ? body : [body];

  const failed: string[] = [];
  const succeededThreadIds: string[] = [];

  for (const record of records) {
    try {
      if (record.read_at) {
        await rpcUser(c.var.db, "clear_thread_state", {
          user_id: userId,
          p_thread_id: record.thread_id,
          p_read_at: record.read_at,
          ...(record.bumped_at ? { p_bumped_at: record.bumped_at } : {}),
        });
      }

      // Apply any remaining state fields. Skip the upsert entirely if the
      // record only carries a read_at (handled above).
      //
      // Note on read_at: the client's read marker is processed exclusively by
      // the clear_thread_state branch above (race-safe). The upsert here
      // never opts in to writing read_at (p_set_read_at: false) so a payload
      // like {active: true} doesn't clobber the existing read marker — that
      // was the source of the "click 'To do' on a read thread, then it
      // becomes unread again" bug.
      const hasActive = record.active !== undefined;
      const hasTask = record.task !== undefined;
      const hasToRead = record.to_read !== undefined;
      const hasUrgent = record.urgent !== undefined;
      const hasImportance = record.importance !== undefined;
      const hasOrder = record.order !== undefined;
      const hasOn = record.on !== undefined;
      const hasAt = record.at !== undefined;
      const hasBumped = record.bumped_at !== undefined && !record.read_at;

      if (hasActive || hasTask || hasToRead || hasUrgent || hasImportance || hasOrder || hasOn || hasAt || hasBumped) {
        await rpcUser(c.var.db, "upsert_thread_state", {
          user_id: userId,
          p_thread_id: record.thread_id,
          p_active: hasActive ? record.active : false,
          p_task: hasTask ? record.task : false,
          p_to_read: hasToRead ? record.to_read : false,
          p_urgent: hasUrgent ? record.urgent : false,
          p_importance: hasImportance ? record.importance : 50,
          p_set_active: hasActive,
          p_set_task: hasTask,
          p_set_to_read: hasToRead,
          p_set_urgent: hasUrgent,
          p_set_importance: hasImportance,
          p_set_read_at: false,
          p_set_order: hasOrder,
          p_set_on: hasOn,
          p_set_at: hasAt,
          ...(hasOrder ? { p_order: record.order } : {}),
          ...(hasOn ? { p_on: record.on } : {}),
          ...(hasAt ? { p_at: record.at } : {}),
          ...(hasBumped ? { p_bumped_at: record.bumped_at } : {}),
        });
      }

      succeededThreadIds.push(record.thread_id);
    } catch (err) {
      if (mapPgError(err)) {
        failed.push(record.thread_id);
      } else {
        throw err;
      }
    }
  }

  notifyUserSync(c, userId);

  // Notify TwistSync for source onThreadRead / onThreadToDo callbacks
  const priorityIds = new Set<string>();
  for (const threadId of succeededThreadIds) {
    try {
      const priorityId = await getPriorityForThread(c.var.db, threadId, c.var.user.id);
      priorityIds.add(priorityId);
    } catch {
      // Thread may not exist; skip
    }
  }
  for (const priorityId of priorityIds) {
    notifySync(c, priorityId);
  }

  if (failed.length > 0) {
    return c.json({ ok: true, failed });
  }
  return c.json({ ok: true });
});

export default threadState;
