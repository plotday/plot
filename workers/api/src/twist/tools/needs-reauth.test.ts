import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../../db";
import type { Bindings } from "../../env";
import { flagConnectionNeedsReauth } from "./needs-reauth";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

/** A UserSync DO stub so notifyUserSyncByEnv is a clean no-op in tests. */
const ENV = {
  DATABASE_URL,
  USER_SYNC: {
    idFromName: () => "stub",
    get: () => ({ fetch: async () => new Response("ok") }),
  },
} as unknown as Bindings;

/**
 * Seed user + linked contact (the actor) + twist_instance + connection in the
 * given starting needs_reauth state, run `flagConnectionNeedsReauth`, read the
 * row back, and roll back.
 */
async function seedAndFlag(opts: {
  alreadyFlaggedMinsAgo?: number | null;
}): Promise<{ needsReauth: boolean; recoveryPending: boolean; flaggedAt: Date | null }> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const twistInstanceId = randomUUID();
  const userId = randomUUID();
  const actorId = randomUUID();
  const provider = "linkedin";
  let out = { needsReauth: false, recoveryPending: false, flaggedAt: null as Date | null };
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      await sql`INSERT INTO "user" (id, email)
        VALUES (${userId}::uuid, ${`reauth-${userId}@example.test`})`.execute(trx);
      // The actor is a contact linked to the user; the helper resolves
      // user_id from contact.id = actorId.
      await sql`INSERT INTO contact (id, user_id)
        VALUES (${actorId}::uuid, ${userId}::uuid)`.execute(trx);
      await sql`INSERT INTO twist_instance (id, twist_id, owner_id, name, draft)
        VALUES (${twistInstanceId}::uuid, 1, ${userId}::uuid, 'LinkedIn', false)`.execute(trx);
      const alreadyFlagged =
        opts.alreadyFlaggedMinsAgo == null
          ? null
          : sql`now() - (${opts.alreadyFlaggedMinsAgo} * interval '1 minute')`;
      await sql`INSERT INTO twist_instance_connection
          (twist_instance_id, user_id, provider, actor_id,
           initial_sync_started_at, recovery_pending, needs_reauth_at)
        VALUES (${twistInstanceId}::uuid, ${userId}::uuid, ${provider}, ${actorId}::uuid,
          now(), false, ${alreadyFlagged})`.execute(trx);
      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      await flagConnectionNeedsReauth(trx, ENV, {
        twistInstanceId,
        provider,
        actorId,
        details: { trigger: "token_missing", reason: "no stored credentials" },
      });

      const res = await sql<{
        needs_reauth_at: Date | null;
        recovery_pending: boolean;
      }>`SELECT needs_reauth_at, recovery_pending
         FROM twist_instance_connection
         WHERE twist_instance_id = ${twistInstanceId}::uuid`.execute(trx);
      const r = res.rows[0];
      out = {
        needsReauth: r.needs_reauth_at !== null,
        recoveryPending: r.recovery_pending,
        flaggedAt: r.needs_reauth_at,
      };
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
  return out;
}

describe.skipIf(!DATABASE_URL)("flagConnectionNeedsReauth", () => {
  it("flags needs_reauth_at and recovery_pending for the actor's connection", async () => {
    const row = await seedAndFlag({ alreadyFlaggedMinsAgo: null });
    expect(row.needsReauth).toBe(true);
    expect(row.recoveryPending).toBe(true);
  });

  it("does not overwrite an existing needs_reauth_at (idempotent)", async () => {
    const row = await seedAndFlag({ alreadyFlaggedMinsAgo: 60 });
    expect(row.needsReauth).toBe(true);
    // The original timestamp (60 min ago) must be preserved, not bumped to now.
    expect(row.flaggedAt).not.toBeNull();
    expect(Date.now() - row.flaggedAt!.getTime()).toBeGreaterThan(30 * 60 * 1000);
  });
});
