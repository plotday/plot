import type { Kysely } from "kysely";

import type { DB } from "../../db-types";
import { rpcUser } from "../../rpc";

/**
 * Write a per-user thread_state row for a thread. The `reason` chooses
 * which (if any) of the three independent state booleans to set:
 *
 *   - 'active' — user-/note-driven (e.g. todo-tagged a note themselves).
 *                Lands in the Doing section of the unified feed.
 *   - 'task'   — connector-driven (Linear / Todoist assignment, twist
 *                integration tool). Lands on the task list; the user
 *                explicitly flips it to active when they decide to start.
 *   - 'add'    — filed for visibility, no state flags. Default row.
 *   - 'unread' — same as 'add'; kept as a distinct value for log clarity.
 *
 * Never throws — best-effort write.
 */
export async function createSchedule(
  db: Kysely<DB>,
  userId: string,
  threadId: string,
  reason: "unread" | "task" | "active" | "add"
): Promise<void> {
  try {
    await rpcUser(db, "upsert_thread_state", {
      user_id: userId,
      p_thread_id: threadId,
      p_active: reason === "active",
      p_task: reason === "task",
      p_to_read: false,
      p_urgent: false,
      p_importance: 50,
      p_set_active: reason === "active",
      p_set_task: reason === "task",
      p_set_to_read: false,
      p_set_urgent: false,
      p_set_importance: false,
    });
  } catch (error) {
    console.error("[thread_state] Failed to write thread_state:", error);
  }
}
