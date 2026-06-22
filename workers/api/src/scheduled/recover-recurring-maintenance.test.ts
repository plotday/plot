import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { selectActiveMaintenanceConnections } from "./recover-recurring-maintenance";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

type ConnState = {
  /** When true, initial_sync_completed_at is set. Default true. */
  completed?: boolean;
  /** When true, needs_reauth_at is set (auth broken). Default false. */
  needsReauth?: boolean;
  /** When true, recovery_pending is set. Default false. */
  recoveryPending?: boolean;
  /** twist_instance lifecycle. Default active. */
  archived?: boolean;
  suspended?: boolean;
  draft?: boolean;
};

/**
 * Seed one twist_instance + twist_instance_connection in the given state
 * (triggers disabled so FKs to absent rows are fine), run
 * selectActiveMaintenanceConnections, and roll back. Returns the seeded
 * twistInstanceId so the caller can check inclusion.
 */
async function seedAndSelect(
  state: ConnState
): Promise<{ twistInstanceId: string; selected: boolean }> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const twistInstanceId = randomUUID();
  const userId = randomUUID();
  const provider = "linear";
  const completed = state.completed !== false; // default true

  let captured: Awaited<ReturnType<typeof selectActiveMaintenanceConnections>> =
    [];
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      await sql`INSERT INTO twist_instance
          (id, twist_id, owner_id, name, archived_at, suspended_at, draft)
        VALUES (${twistInstanceId}::uuid, 1, ${userId}::uuid, 'Linear',
          ${state.archived ? sql`now()` : null},
          ${state.suspended ? sql`now()` : null},
          ${state.draft ?? false})`.execute(trx);

      await sql`INSERT INTO twist_instance_connection
          (twist_instance_id, user_id, provider, actor_id,
           initial_sync_started_at, initial_sync_completed_at,
           recovery_pending, needs_reauth_at)
        VALUES (${twistInstanceId}::uuid, ${userId}::uuid, ${provider}, ${randomUUID()}::uuid,
          now() - interval '60 minutes',
          ${completed ? sql`now()` : null},
          ${state.recoveryPending ?? false},
          ${state.needsReauth ? sql`now()` : null})`.execute(trx);

      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      captured = await selectActiveMaintenanceConnections(trx);
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }

  return {
    twistInstanceId,
    selected: captured.some((c) => c.twistInstanceId === twistInstanceId),
  };
}

describe.skipIf(!DATABASE_URL)("selectActiveMaintenanceConnections", () => {
  it("selects an active connection that has completed initial sync", async () => {
    const { selected } = await seedAndSelect({ completed: true });
    expect(selected).toBe(true);
  });

  it("ignores a connection whose initial sync never completed", async () => {
    const { selected } = await seedAndSelect({ completed: false });
    expect(selected).toBe(false);
  });

  it("ignores a connection already flagged for recovery", async () => {
    const { selected } = await seedAndSelect({
      completed: true,
      recoveryPending: true,
    });
    expect(selected).toBe(false);
  });

  it("ignores a connection whose auth is broken (needs re-auth)", async () => {
    const { selected } = await seedAndSelect({
      completed: true,
      needsReauth: true,
    });
    expect(selected).toBe(false);
  });

  it("ignores a connection on an archived twist instance", async () => {
    const { selected } = await seedAndSelect({ completed: true, archived: true });
    expect(selected).toBe(false);
  });

  it("ignores a connection on a suspended twist instance", async () => {
    const { selected } = await seedAndSelect({
      completed: true,
      suspended: true,
    });
    expect(selected).toBe(false);
  });

  it("ignores a connection on a draft twist instance", async () => {
    const { selected } = await seedAndSelect({ completed: true, draft: true });
    expect(selected).toBe(false);
  });
});
