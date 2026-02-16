import type { Context } from "hono";
import type { Kysely } from "kysely";

import type { DB } from "../../db";
import type { Bindings } from "../../env";
import { createLogger } from "@plotday/worker-util";
import { disposeRpc } from "../../utils/rpc";

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
        const result = await syncNotifyDO.fetch(
          new Request("http://do/notify", {
            method: "POST",
            body: JSON.stringify({ priorityId }),
          })
        );
        disposeRpc(result);
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
        const result = await userSyncDO.fetch(
          new Request("http://do/notify", {
            method: "POST",
            body: JSON.stringify({ id: userId }),
          })
        );
        disposeRpc(result);
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
 * Look up the priority_id for an activity.
 */
export async function getPriorityForActivity(db: Kysely<DB>, activityId: string): Promise<string> {
  const row = await db
    .selectFrom("activity")
    .select("priority_id")
    .where("id", "=", activityId)
    .executeTakeFirstOrThrow();
  return row.priority_id;
}

/**
 * Look up the priority_id for a note (via its parent activity).
 */
export async function getPriorityForNote(db: Kysely<DB>, noteId: string): Promise<string> {
  const row = await db
    .selectFrom("note")
    .innerJoin("activity", "activity.id", "note.activity_id")
    .select("activity.priority_id")
    .where("note.id", "=", noteId)
    .executeTakeFirstOrThrow();
  return row.priority_id;
}
