import type { Context } from "hono";
import type { Kysely } from "kysely";

import type { DB } from "../../db";
import type { Bindings } from "../../env";
import { createLogger } from "@plotday/worker-util";

/**
 * Notify SyncNotify DO for a priority-scoped change.
 * Fire-and-forget via waitUntil to avoid blocking the response.
 */
export function notifySync(c: Context<{ Bindings: Bindings }>, priorityId: string) {
  c.executionCtx.waitUntil(
    (async () => {
      try {
        const syncNotifyId = c.env.SYNC_NOTIFY.idFromName(priorityId);
        const syncNotifyDO = c.env.SYNC_NOTIFY.get(syncNotifyId);
        await syncNotifyDO.fetch(
          new Request("http://do/notify", {
            method: "POST",
            body: JSON.stringify({ priorityId }),
          })
        );
      } catch (error) {
        const logger = createLogger({ operation: "notifySync" });
        logger.error("Error notifying SyncNotify DO", error as Error, {
          priority_id: priorityId,
        });
      }
    })()
  );
}

/**
 * Directly notify a user's UserSync DO for user-only changes (activity-read, user-settings).
 * Fire-and-forget via waitUntil to avoid blocking the response.
 */
export function notifyUserSync(c: Context<{ Bindings: Bindings }>, userId: string) {
  c.executionCtx.waitUntil(
    (async () => {
      try {
        const userSyncId = c.env.USER_SYNC.idFromName(userId);
        const userSyncDO = c.env.USER_SYNC.get(userSyncId);
        await userSyncDO.fetch(
          new Request("http://do/notify", {
            method: "POST",
            body: JSON.stringify({ id: userId }),
          })
        );
      } catch (error) {
        const logger = createLogger({ operation: "notifyUserSync" });
        logger.error("Error notifying UserSync DO", error as Error, {
          user_id: userId,
        });
      }
    })()
  );
}

/**
 * Look up the priority_id for a thread via thread_priority for a given user.
 */
export async function getPriorityForThread(db: Kysely<DB>, threadId: string, userId: string): Promise<string> {
  const row = await db
    .selectFrom("thread_priority")
    .select("priority_id")
    .where("thread_id", "=", threadId)
    .where("user_id", "=", userId)
    .executeTakeFirstOrThrow();
  return row.priority_id;
}

/** @deprecated Use getPriorityForThread */
export const getPriorityForActivity = getPriorityForThread;

/**
 * Look up the priority_id for a note (via thread_priority for a given user).
 */
export async function getPriorityForNote(db: Kysely<DB>, noteId: string, userId: string): Promise<string> {
  const row = await db
    .selectFrom("note")
    .innerJoin("thread_priority", "thread_priority.thread_id", "note.thread_id")
    .select("thread_priority.priority_id")
    .where("note.id", "=", noteId)
    .where("thread_priority.user_id", "=", userId)
    .executeTakeFirstOrThrow();
  return row.priority_id;
}
