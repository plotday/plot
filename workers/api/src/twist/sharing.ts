import { sql, type Kysely } from "kysely";
import type { DB } from "../db-types";

/**
 * Invoke the privileged `update_thread_dropped_contacts` DB function.
 * Callers must have independently confirmed (via the platform reconciliation
 * heuristic) that the change is correct — this RPC bypasses share_thread's
 * user access-control check by design. See
 * `update_thread_dropped_contacts.sql` for the trust contract.
 *
 * Dropped contacts remain in `thread.contacts` (so they retain thread
 * visibility) but are recorded in `thread.dropped_contacts` so clients
 * exclude them from outbound defaults and badge logic.
 */
export async function updateThreadDroppedContacts(
  db: Kysely<DB>,
  threadId: string,
  toDrop: string[],
  toUndrop: string[],
): Promise<void> {
  if (toDrop.length === 0 && toUndrop.length === 0) return;
  await sql`
    SELECT public.update_thread_dropped_contacts(
      ${threadId}::uuid,
      ${sql.val(toDrop)}::uuid[],
      ${sql.val(toUndrop)}::uuid[]
    )
  `.execute(db);
}
