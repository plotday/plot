import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { getPersonalConnectionCount, getTeamConnectionCount } from "./limits";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

/**
 * Seed one source twist + twist_instance + a single channel (enabled or not),
 * then return what the connection-count function reports for that scope. The
 * whole thing runs in a transaction that is rolled back, so the DB is left
 * untouched. FK/identity triggers are disabled via `session_replication_role`
 * during seeding (mirrors recover-stuck-syncs.test.ts).
 */
async function seedAndCount(opts: {
  scope: "personal" | "team";
  channelEnabled: boolean;
}): Promise<number> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const teamId = 987654;
  const twistInstanceId = randomUUID();

  let count = 0;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      // A personal-environment source twist satisfies the twist CHECK
      // constraint (user_id set, publisher_id null) and is all the count
      // queries inspect (is_source = true, premium = false).
      const twist = await sql<{ id: string }>`
        INSERT INTO twist
          (twist_package_id, environment, user_id, name, handle, version,
           is_source, premium)
        VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
          'LinkedIn', 'linkedin', '1.0.0', true, false)
        RETURNING id`.execute(trx);
      const twistId = twist.rows[0].id;

      await sql`INSERT INTO twist_instance
          (id, twist_id, owner_id, name, team_id)
        VALUES (${twistInstanceId}::uuid, ${twistId}, ${userId}::uuid,
          'LinkedIn', ${opts.scope === "team" ? teamId : null})`.execute(trx);

      // channel.id is GENERATED ALWAYS AS IDENTITY — omit it.
      await sql`INSERT INTO channel
          (twist_instance_id, channel_id, title, enabled)
        VALUES (${twistInstanceId}::uuid, 'linkedin', 'LinkedIn',
          ${opts.channelEnabled})`.execute(trx);

      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      count =
        opts.scope === "personal"
          ? await getPersonalConnectionCount(trx, userId)
          : await getTeamConnectionCount(trx, String(teamId));

      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }

  return count;
}

// A "stuck" connection — needs_reauth set but every channel disabled — must not
// consume a connection slot. The count is gated on EXISTS(enabled channel), so
// disabling the last channel drops it out of the quota for both scopes.
describe.skipIf(!DATABASE_URL)("connection quota excludes stuck instances", () => {
  it("personal: an instance with an enabled channel counts", async () => {
    expect(await seedAndCount({ scope: "personal", channelEnabled: true })).toBe(
      1
    );
  });

  it("personal: an instance with no enabled channel does NOT count", async () => {
    expect(
      await seedAndCount({ scope: "personal", channelEnabled: false })
    ).toBe(0);
  });

  it("team: an instance with an enabled channel counts", async () => {
    expect(await seedAndCount({ scope: "team", channelEnabled: true })).toBe(1);
  });

  it("team: an instance with no enabled channel does NOT count", async () => {
    expect(await seedAndCount({ scope: "team", channelEnabled: false })).toBe(0);
  });
});
