import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpc } from "../../rpc";
import { createLogger } from "@plotday/worker-util";

const priorityRules = new Hono<{ Bindings: Bindings }>();

type InsertedRule = { id: string };

// POST /sync/priority-rules — receive a priority rule from the app and apply it retroactively.
// Accepts both new-shape payloads (type: content | topic) and old-shape
// payloads (type: channel | contact_topics) for apiVersion < 3 clients, which
// are translated into the new `type='topic'` shape before insertion.
priorityRules.post("/sync/priority-rules", async (c) => {
  const body = await c.req.json();
  const userId = c.var.user.id;
  const logger = createLogger({ component: "sync-priority-rules" });

  const rule = body.rule || body;

  if (!rule.type || !rule.priority_id) {
    return c.json({ error: "type and priority_id are required" }, 400);
  }
  if (!["content", "topic", "contact_topics", "channel"].includes(rule.type)) {
    return c.json({ error: "type must be content, topic, contact_topics, or channel" }, 400);
  }

  // Translate legacy payload shapes into one or more new-shape inserts.
  type InsertRow = {
    id?: string;
    priority_id: string;
    type: "content" | "topic";
    embedding: unknown;
    topic: string | null;
    label: string | null;
    anchor_thread_id: string | null;
  };

  const rows: InsertRow[] = [];
  const commonFields = {
    priority_id: rule.priority_id as string,
    label: (rule.label ?? null) as string | null,
    anchor_thread_id: (rule.anchor_thread_id ?? null) as string | null,
  };

  if (rule.type === "content") {
    rows.push({
      id: rule.id,
      ...commonFields,
      type: "content",
      embedding: rule.embedding ?? null,
      topic: null,
    });
  } else if (rule.type === "topic") {
    rows.push({
      id: rule.id,
      ...commonFields,
      type: "topic",
      embedding: null,
      topic: rule.topic ?? null,
    });
  } else if (rule.type === "channel") {
    if (rule.channel_id == null) {
      return c.json({ error: "channel_id required for channel rules" }, 400);
    }
    rows.push({
      id: rule.id,
      ...commonFields,
      type: "topic",
      embedding: null,
      topic: `channel:${rule.channel_id}`,
    });
  } else if (rule.type === "contact_topics") {
    // Flatten criteria.topics + criteria.contacts into one rule per id.
    const criteria = rule.criteria ?? {};
    const topicIds: string[] = Array.isArray(criteria.topics) ? criteria.topics : [];
    const contactIds: string[] = Array.isArray(criteria.contacts) ? criteria.contacts : [];
    const all = [...topicIds, ...contactIds];
    if (all.length === 0) {
      return c.json({ error: "contact_topics rules require criteria.topics or criteria.contacts" }, 400);
    }
    for (let i = 0; i < all.length; i++) {
      rows.push({
        // Only the first row reuses the caller-provided id (if any).
        id: i === 0 ? rule.id : undefined,
        ...commonFields,
        type: "topic",
        embedding: null,
        topic: all[i],
      });
    }
  }

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    const inserted: InsertedRule[] = [];
    for (const row of rows) {
      const ins = await sql<InsertedRule>`
        INSERT INTO priority_rule (id, user_id, priority_id, type, embedding, topic, label, anchor_thread_id)
        VALUES (
          COALESCE(${row.id ?? null}::uuid, uuidv7()),
          ${userId}::uuid,
          ${row.priority_id}::uuid,
          ${row.type},
          ${row.embedding ?? null}::halfvec,
          ${row.topic},
          ${row.label},
          ${row.anchor_thread_id}::uuid
        )
        RETURNING id
      `.execute(trx).then((r) => r.rows[0]);
      inserted.push(ins);
    }

    // Apply the first inserted rule retroactively (one anchor thread, one rule
    // semantically; additional rows are just the multi-uuid spread).
    const primaryId = inserted[0]?.id;
    let movedThreadIds: string[] = [];
    if (primaryId) {
      try {
        const moved = await rpc(trx, "apply_priority_rule", {
          p_rule_id: primaryId,
        });
        if (Array.isArray(moved)) {
          movedThreadIds = moved.map((m: any) => m.thread_id);
        }
      } catch (error) {
        logger.error("Retroactive rule application failed", error as Error, {
          rule_id: primaryId,
        });
        c.var.tracker.captureException(error as Error);
      }
    }

    return { id: primaryId, moved_thread_ids: movedThreadIds, ids: inserted.map((r) => r.id) };
  });

  return c.json(result);
});

export default priorityRules;
