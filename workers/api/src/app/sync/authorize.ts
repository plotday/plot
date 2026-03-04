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
 * Assert that a user has access to a thread's priority.
 * Looks up the thread's priority_id and checks access.
 * Throws a 403 error if access is denied.
 */
export async function assertThreadAccess(
  trx: Kysely<DB>,
  userId: string,
  threadId: string
) {
  const thread = await trx
    .selectFrom("thread")
    .select("priority_id")
    .where("id", "=", threadId)
    .executeTakeFirst();

  if (!thread) {
    throw Object.assign(new Error("Thread not found"), { status: 404 });
  }

  await assertPriorityAccess(trx, userId, thread.priority_id);
}

/** @deprecated Use assertThreadAccess */
export const assertActivityAccess = assertThreadAccess;
