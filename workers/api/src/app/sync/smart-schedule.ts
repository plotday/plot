import type { Kysely } from "kysely";

import type { DB } from "../../db-types";
import { rpcUser } from "../../rpc";

/**
 * Write a per-user thread_state row for a thread. The `reason` chooses
 * whether to set the `active` state boolean:
 *
 *   - 'active' — user-/note-driven (e.g. todo-tagged a note themselves).
 *                Lands in the Doing section of the unified feed.
 *   - 'add'    — filed for visibility, no state flags. Default row.
 *   - 'unread' — same as 'add'; kept as a distinct value for log clarity.
 *
 * Never throws — best-effort write.
 */
export async function createSchedule(
  db: Kysely<DB>,
  userId: string,
  threadId: string,
  reason: "unread" | "active" | "add"
): Promise<void> {
  try {
    await rpcUser(db, "upsert_thread_state", {
      user_id: userId,
      p_thread_id: threadId,
      p_active: reason === "active",
      p_urgent: false,
      p_importance: 50,
      p_set_active: reason === "active",
      p_set_urgent: false,
      p_set_importance: false,
    });
  } catch (error) {
    console.error("[thread_state] Failed to write thread_state:", error);
  }
}
