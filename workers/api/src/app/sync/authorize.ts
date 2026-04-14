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
 * Assert that a user has access to a thread via thread_priority membership.
 * Throws a 403 error if access is denied.
 */
export async function assertThreadAccess(
  trx: Kysely<DB>,
  userId: string,
  threadId: string
) {
  const row = await trx
    .selectFrom("thread_priority")
    .select("thread_id")
    .where("thread_id", "=", threadId)
    .where("user_id", "=", userId)
    .executeTakeFirst();

  if (!row) {
    throw Object.assign(new Error("Access denied"), { status: 403 });
  }
}

/** @deprecated Use assertThreadAccess */
export const assertActivityAccess = assertThreadAccess;
