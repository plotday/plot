import { type Kysely } from "kysely";

import type { DB } from "../db-types";

/**
 * Resolve the canonical contact for a user, deterministically.
 *
 * Several flows need "the user's own contact" as an actor id — binding a
 * hosted auth token (onAuth), enabling channels at activation (activateDraft),
 * and the manual channel enable/disable endpoints (getCurrentActorId). These
 * MUST all agree: `channel_config.enabledBy` has to equal the actor whose
 * `auth_token:{provider}:{actor}` key holds the credential, or sync throws
 * "has no stored credentials — reconnect".
 *
 * A bare `SELECT ... FROM contact WHERE user_id = ?` `.executeTakeFirst()`
 * returns an ARBITRARY row for a user with more than one contact (no ORDER BY),
 * and two such queries can disagree — which is exactly how the enabling actor
 * drifted away from the token actor. Prefer the PRIMARY contact (unique per
 * user) so every caller lands on the same row; fall back to the oldest contact
 * only if a user somehow has none marked primary.
 */
export async function resolveOwnerContact(
  db: Kysely<DB>,
  userId: string
): Promise<{ id: string; name: string | null } | null> {
  const primary = await db
    .selectFrom("contact")
    .select(["id", "name"])
    .where("user_id", "=", userId)
    .where("primary", "=", true)
    .executeTakeFirst();
  if (primary) return primary;

  const oldest = await db
    .selectFrom("contact")
    .select(["id", "name"])
    .where("user_id", "=", userId)
    .orderBy("created_at", "asc")
    .executeTakeFirst();
  return oldest ?? null;
}
