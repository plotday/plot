import type { Kysely } from "kysely";

import type { DB } from "../../db-types";
import { rpcUser } from "../../rpc";

/**
 * Create a per-user schedule for a thread with the given reason.
 * Uses the sentinel date [1970-01-01,) — the app handles
 * smart scheduling locally based on attention window settings.
 * Never throws — schedule creation should not fail the caller.
 */
export async function createSchedule(
  db: Kysely<DB>,
  userId: string,
  threadId: string,
  reason: "unread" | "task" | "add",
  outstandingTasks?: boolean
): Promise<void> {
  try {
    const schedule: Record<string, unknown> = {
      thread_id: threadId,
      user_id: userId,
      order: 0,
      reason,
      on: "[1970-01-01,)",
    };
    if (outstandingTasks !== undefined) {
      schedule.outstanding_tasks = outstandingTasks;
    }
    await rpcUser(db, "upsert_schedule", {
      user_id: userId,
      p_schedule: schedule,
      p_defaults: {},
    } as any);
  } catch (error) {
    console.error("[schedule] Failed to create schedule:", error);
  }
}
