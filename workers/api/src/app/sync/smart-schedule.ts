import type { Kysely } from "kysely";

import type { DB } from "../../db-types";
import { rpcUser } from "../../rpc";

/**
 * Write a per-user thread_state row for a thread. The `reason` legacy values
 * map to action_type:
 *   - 'task'   → action_type = 'do'    (link assignment, todo-tagged note)
 *   - 'add'    → action_type = 'update' (user dropped it on their inbox)
 *   - 'unread' → action_type = 'update' (filed for visibility, no action)
 *
 * Never throws — best-effort write.
 */
export async function createSchedule(
  db: Kysely<DB>,
  userId: string,
  threadId: string,
  reason: "unread" | "task" | "add"
): Promise<void> {
  try {
    const actionType = reason === "task" ? "do" : "update";
    await rpcUser(db, "upsert_thread_state", {
      user_id: userId,
      p_thread_id: threadId,
      p_action_type: actionType,
      p_urgent: false,
      p_importance: 50,
      p_set_action_type: true,
      p_set_urgent: false,
      p_set_importance: false,
    });
  } catch (error) {
    console.error("[thread_state] Failed to write thread_state:", error);
  }
}
