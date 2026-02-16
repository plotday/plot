import type { Kysely } from "kysely";

import type { DB } from "../../db-types";
import { rpcUser } from "../../rpc";

/**
 * Assert that a user has access to a priority.
 * Throws a 403 error if access is denied.
 */
export async function assertPriorityAccess(
  trx: Kysely<DB>,
  userId: string,
  priorityId: string
) {
  const result = await rpcUser(trx, "has_priority_access", {
    user_id: userId,
    priority_id: priorityId,
  });
  if (!result) {
    throw Object.assign(new Error("Access denied"), { status: 403 });
  }
}

/**
 * Assert that a user has access to an activity's priority.
 * Looks up the activity's priority_id and checks access.
 * Throws a 403 error if access is denied.
 */
export async function assertActivityAccess(
  trx: Kysely<DB>,
  userId: string,
  activityId: string
) {
  const activity = await trx
    .selectFrom("activity")
    .select("priority_id")
    .where("id", "=", activityId)
    .executeTakeFirst();

  if (!activity) {
    throw Object.assign(new Error("Activity not found"), { status: 404 });
  }

  await assertPriorityAccess(trx, userId, activity.priority_id);
}
