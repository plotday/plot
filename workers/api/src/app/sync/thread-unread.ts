import { Hono } from "hono";

import { mapPgError } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { notifyThreadStateChange } from "./thread-state";

const threadUnread = new Hono<{ Bindings: Bindings }>();

/** A legacy POST /sync/thread-unread record (single element of the body). */
export interface LegacyThreadUnreadRecord {
  thread_id: string;
  read_at?: string | null;
  importance?: number;
  bumped_at?: string | null;
  // `urgency` may still arrive from very old clients; it is intentionally
  // ignored (the column was dropped in the thread_unread → thread_state rename).
  urgency?: string | null;
}

/**
 * Translate one legacy /sync/thread-unread record onto the thread_state RPC that
 * replaces its old behavior. Pure (no DB, no Hono) so the mapping is unit- and
 * integration-testable in isolation — see ./thread-unread.test.ts.
 *
 *   - read_at present → clear_thread_state  (mark read, race-safe — replaces the
 *                       old clear_thread_unread)
 *   - read_at absent  → upsert_thread_state with read_at left NULL (mark unread —
 *                       replaces the old upsert_thread_unread). p_set_read_at opts
 *                       in to writing read_at; omitting p_read_at defaults it to
 *                       NULL. importance is carried through only when supplied.
 */
export type ThreadStateRpcCall =
  | {
      fn: "clear_thread_state";
      args: {
        user_id: string;
        p_thread_id: string;
        p_read_at: string;
        p_bumped_at?: string;
      };
    }
  | {
      fn: "upsert_thread_state";
      args: {
        user_id: string;
        p_thread_id: string;
        p_set_read_at: true;
        p_importance: number;
        p_set_importance: boolean;
        p_bumped_at?: string;
      };
    };

export function legacyThreadUnreadToRpc(
  userId: string,
  record: LegacyThreadUnreadRecord,
): ThreadStateRpcCall {
  if (record.read_at) {
    return {
      fn: "clear_thread_state",
      args: {
        user_id: userId,
        p_thread_id: record.thread_id,
        p_read_at: record.read_at,
        ...(record.bumped_at ? { p_bumped_at: record.bumped_at } : {}),
      },
    };
  }

  const hasImportance = record.importance !== undefined;
  return {
    fn: "upsert_thread_state",
    args: {
      user_id: userId,
      p_thread_id: record.thread_id,
      p_set_read_at: true,
      p_importance: hasImportance ? (record.importance as number) : 50,
      p_set_importance: hasImportance,
      ...(record.bumped_at ? { p_bumped_at: record.bumped_at } : {}),
    },
  };
}

// POST /sync/thread-unread — BACKWARDS-COMPATIBILITY SHIM. DO NOT REMOVE.
//
// The per-user `thread_unread` table was renamed to `thread_state` and the live
// endpoint moved to POST /sync/thread-state (commit 3ff3bffa, "Replace urgency +
// per-user schedule with action_type on thread_state"). That commit deleted this
// route, which silently broke read-state sync for every client that had not yet
// shipped the rename: those clients keep POSTing their read markers here and were
// getting a 404, so a thread read on an old client never cleared on the server or
// on the user's other devices. This shim restores the old route and translates
// its payload onto the new RPCs via legacyThreadUnreadToRpc. Keep it until old
// clients are gone (the stable-routes.test.ts manifest guards against re-deletion).
//
// Legacy payload (single object or array of objects): see LegacyThreadUnreadRecord.
// The observable contract — `{ ok: true }`, or `{ ok: true, failed: [...] }` for
// inaccessible threads — is unchanged from the original handler.
threadUnread.post("/sync/thread-unread", async (c) => {
  const body = await c.req.json();
  const userId = c.var.user.id;
  const records: LegacyThreadUnreadRecord[] = Array.isArray(body) ? body : [body];

  const failed: string[] = [];
  const succeededThreadIds: string[] = [];

  for (const record of records) {
    try {
      const call = legacyThreadUnreadToRpc(userId, record);
      // Dispatch per discriminant so rpcUser sees a concrete fn + matching args.
      if (call.fn === "clear_thread_state") {
        await rpcUser(c.var.db, "clear_thread_state", call.args);
      } else {
        await rpcUser(c.var.db, "upsert_thread_state", call.args);
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

  await notifyThreadStateChange(c, userId, succeededThreadIds);

  if (failed.length > 0) {
    return c.json({ ok: true, failed });
  }
  return c.json({ ok: true });
});

export default threadUnread;
