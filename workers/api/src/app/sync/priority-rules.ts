import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpc } from "../../rpc";
import { createLogger } from "@plotday/worker-util";

const priorityRules = new Hono<{ Bindings: Bindings }>();

// POST /sync/priority-rules — receive a priority rule from the app and apply it retroactively.
// Rules are created locally in the app's Drift table and synced here when online.
// After successful sync, the app deletes the local row.
priorityRules.post("/sync/priority-rules", async (c) => {
  const body = await c.req.json();
  const userId = c.var.user.id;
  const logger = createLogger({ component: "sync-priority-rules" });

  const rule = body.rule || body;

  // Validate required fields
  if (!rule.type || !rule.priority_id) {
    return c.json({ error: "type and priority_id are required" }, 400);
  }
  if (!["content", "contact_topics", "channel"].includes(rule.type)) {
    return c.json({ error: "type must be content, contact_topics, or channel" }, 400);
  }

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    // Insert the priority_rule row
    const insertResult = await sql<{ id: string }>`
      INSERT INTO priority_rule (id, user_id, priority_id, channel_id, type, embedding, criteria, label, anchor_thread_id)
      VALUES (
        COALESCE(${rule.id ?? null}::uuid, uuidv7()),
        ${userId}::uuid,
        ${rule.priority_id}::uuid,
        ${rule.channel_id ?? null}::bigint,
        ${rule.type},
        ${rule.embedding ?? null}::halfvec,
        ${rule.criteria ? JSON.stringify(rule.criteria) : null}::jsonb,
        ${rule.label ?? null},
        ${rule.anchor_thread_id ?? null}::uuid
      )
      RETURNING id
    `.execute(trx).then(r => r.rows[0]);

    // Apply retroactively — move existing matching threads
    let movedThreadIds: string[] = [];
    try {
      const moved = await rpc(trx, "apply_priority_rule", {
        p_rule_id: insertResult.id,
      });
      if (Array.isArray(moved)) {
        movedThreadIds = moved.map((m: any) => m.thread_id);
      }
    } catch (error) {
      // Retroactive application is non-critical
      logger.error("Retroactive rule application failed", error as Error, {
        rule_id: insertResult.id,
      });
      c.var.tracker.captureException(error as Error);
    }

    return { id: insertResult.id, moved_thread_ids: movedThreadIds };
  });

  return c.json(result);
});

export default priorityRules;
