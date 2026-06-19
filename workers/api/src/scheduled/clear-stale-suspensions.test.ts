import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { clearStaleAutoSuspensions } from "./clear-stale-suspensions";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

type SuspendState = {
  /** When false, the instance is not suspended at all. Default true. */
  suspended?: boolean;
  /**
   * Controls suspended_version relative to the live twist.version:
   *  - "stale": an older version (auto-suspension, twist redeployed since)
   *  - "current": the live version (auto-suspension still on this version)
   *  - "null": NULL (manual/operator suspension — durable)
   * Default "stale".
   */
  versionKind?: "stale" | "current" | "null";
  /** twist_instance archived. Default false. */
  archived?: boolean;
};

/**
 * Seed one twist + twist_instance in the given suspension state (triggers
 * disabled so FKs to absent rows are fine), run clearStaleAutoSuspensions,
 * then re-read suspended_at, and roll back. Returns whether the instance was
 * cleared (suspended_at became NULL).
 */
async function seedAndClear(state: SuspendState): Promise<boolean> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const twistInstanceId = randomUUID();
  const userId = randomUUID();
  const liveVersion = "2000000000000";
  const versionKind = state.versionKind ?? "stale";
  const suspended = state.suspended ?? true;

  let clearedAfter = false;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      // owner_id / user_id FKs are re-checked when the UPDATE modifies a row
      // (the clear runs under the default replication role), so seed a real
      // user row rather than a dangling uuid.
      await sql`INSERT INTO "user" (id, email)
        VALUES (${userId}::uuid, ${`stale-suspend-${userId}@example.test`})`.execute(
        trx
      );

      // Real twist row required — clearStaleAutoSuspensions compares
      // twist_instance.suspended_version against twist.version. id is
      // GENERATED ALWAYS AS IDENTITY, so let it auto-assign and capture it.
      const twist = await sql<{ id: string }>`
        INSERT INTO twist
          (twist_package_id, user_id, environment, name, handle, version)
        VALUES (${randomUUID()}::uuid, ${userId}::uuid, 'personal',
          'Linear', 'Linear', ${liveVersion})
        RETURNING id`.execute(trx);
      const twistId = twist.rows[0].id;

      const suspendedVersion =
        versionKind === "stale"
          ? "1000000000000"
          : versionKind === "current"
            ? liveVersion
            : null;

      await sql`INSERT INTO twist_instance
          (id, twist_id, owner_id, name, archived_at, suspended_at, suspended_version, draft)
        VALUES (${twistInstanceId}::uuid, ${twistId}, ${userId}::uuid, 'Linear',
          ${state.archived ? sql`now()` : null},
          ${suspended ? sql`now()` : null},
          ${suspendedVersion},
          false)`.execute(trx);

      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      await clearStaleAutoSuspensions(trx);

      const row = await sql<{ suspended_at: Date | null }>`
        SELECT suspended_at FROM twist_instance WHERE id = ${twistInstanceId}::uuid`.execute(
        trx
      );
      clearedAfter = row.rows[0].suspended_at === null;

      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }

  return clearedAfter;
}

describe.skipIf(!DATABASE_URL)("clearStaleAutoSuspensions", () => {
  it("clears a stale auto-suspension (twist redeployed since suspension)", async () => {
    expect(await seedAndClear({ versionKind: "stale" })).toBe(true);
  });

  it("leaves an auto-suspension on the current version untouched", async () => {
    expect(await seedAndClear({ versionKind: "current" })).toBe(false);
  });

  it("leaves a manual suspension (suspended_version NULL) untouched", async () => {
    expect(await seedAndClear({ versionKind: "null" })).toBe(false);
  });

  it("ignores an instance that is not suspended", async () => {
    // Not suspended → suspended_at already NULL, so nothing to clear and the
    // helper must not select it. The "cleared" assertion is trivially true
    // (already NULL), so instead assert it is not among the returned ids.
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const twistInstanceId = randomUUID();
    const userId = randomUUID();
    let selected = true;
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await sql`INSERT INTO "user" (id, email)
          VALUES (${userId}::uuid, ${`stale-suspend-${userId}@example.test`})`.execute(
          trx
        );
        const twist = await sql<{ id: string }>`
          INSERT INTO twist
            (twist_package_id, user_id, environment, name, handle, version)
          VALUES (${randomUUID()}::uuid, ${userId}::uuid, 'personal',
            'Linear', 'Linear', '2000000000000')
          RETURNING id`.execute(trx);
        await sql`INSERT INTO twist_instance
            (id, twist_id, owner_id, name, suspended_at, suspended_version, draft)
          VALUES (${twistInstanceId}::uuid, ${twist.rows[0].id}, ${userId}::uuid,
            'Linear', null, '1000000000000', false)`.execute(trx);
        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
        const cleared = await clearStaleAutoSuspensions(trx);
        selected = cleared.includes(twistInstanceId);
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
    expect(selected).toBe(false);
  });

  it("leaves a stale auto-suspension on an archived twist instance untouched", async () => {
    expect(await seedAndClear({ versionKind: "stale", archived: true })).toBe(
      false
    );
  });

  it("returns the ids it cleared", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const twistInstanceId = randomUUID();
    const userId = randomUUID();
    let returnedIds: string[] = [];
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await sql`INSERT INTO "user" (id, email)
          VALUES (${userId}::uuid, ${`stale-suspend-${userId}@example.test`})`.execute(
          trx
        );
        const twist = await sql<{ id: string }>`
          INSERT INTO twist
            (twist_package_id, user_id, environment, name, handle, version)
          VALUES (${randomUUID()}::uuid, ${userId}::uuid, 'personal',
            'Linear', 'Linear', '2000000000000')
          RETURNING id`.execute(trx);
        await sql`INSERT INTO twist_instance
            (id, twist_id, owner_id, name, suspended_at, suspended_version, draft)
          VALUES (${twistInstanceId}::uuid, ${twist.rows[0].id}, ${userId}::uuid,
            'Linear', now(), '1000000000000', false)`.execute(trx);
        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
        returnedIds = await clearStaleAutoSuspensions(trx);
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
    expect(returnedIds).toContain(twistInstanceId);
  });
});
