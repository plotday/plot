import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import {
  selectStuckSyncCandidates,
  recoveryAction,
  flagForRetry,
  giveUpStuckSync,
  MAX_INITIAL_SYNC_ATTEMPTS,
  type StuckSyncCandidate,
} from "./recover-stuck-syncs";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

type ConnState = {
  /** ms ago the initial sync started; null = never started. Default 60 min. */
  startedMinsAgo?: number | null;
  /** When true, the sync is marked completed. Default false. */
  completed?: boolean;
  /** Default false. */
  recoveryPending?: boolean;
  /** When true, needs_reauth_at is set (auth broken). Default false. */
  needsReauth?: boolean;
  /** twist_instance lifecycle. Default active. */
  archived?: boolean;
  suspended?: boolean;
  draft?: boolean;
};

/**
 * Seed one twist + twist_instance + twist_instance_connection in the given
 * state (triggers disabled so FKs to absent rows are fine), run
 * selectStuckSyncCandidates with a 30-min cutoff, and roll back. Returns
 * whether the seeded connection was selected.
 */
async function seedAndSelect(state: ConnState): Promise<boolean> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const twistInstanceId = randomUUID();
  const userId = randomUUID();
  const provider = "linear";
  const startedMinsAgo =
    state.startedMinsAgo === undefined ? 60 : state.startedMinsAgo;

  let captured: Awaited<ReturnType<typeof selectStuckSyncCandidates>> = [];
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      // FK triggers are disabled under replica, and selectStuckSyncCandidates
      // only joins twist_instance — so an arbitrary twist_id without a real
      // twist row is fine here.
      await sql`INSERT INTO twist_instance
          (id, twist_id, owner_id, name, archived_at, suspended_at, draft)
        VALUES (${twistInstanceId}::uuid, 1, ${userId}::uuid, 'Linear',
          ${state.archived ? sql`now()` : null},
          ${state.suspended ? sql`now()` : null},
          ${state.draft ?? false})`.execute(trx);

      const startedAt =
        startedMinsAgo === null
          ? null
          : sql`now() - (${startedMinsAgo} * interval '1 minute')`;

      await sql`INSERT INTO twist_instance_connection
          (twist_instance_id, user_id, provider, actor_id,
           initial_sync_started_at, initial_sync_completed_at,
           recovery_pending, needs_reauth_at)
        VALUES (${twistInstanceId}::uuid, ${userId}::uuid, ${provider}, ${randomUUID()}::uuid,
          ${startedAt},
          ${state.completed ? sql`now()` : null},
          ${state.recoveryPending ?? false},
          ${state.needsReauth ? sql`now()` : null})`.execute(trx);

      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      const cutoff = new Date(Date.now() - 30 * 60 * 1000);
      captured = await selectStuckSyncCandidates(trx, cutoff);
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }

  return captured.some((c) => c.twistInstanceId === twistInstanceId);
}

describe.skipIf(!DATABASE_URL)("selectStuckSyncCandidates", () => {
  it("selects a sync started long ago that never completed", async () => {
    expect(await seedAndSelect({ startedMinsAgo: 60 })).toBe(true);
  });

  it("ignores a completed sync", async () => {
    expect(await seedAndSelect({ startedMinsAgo: 60, completed: true })).toBe(
      false
    );
  });

  it("ignores a sync still within the grace window", async () => {
    expect(await seedAndSelect({ startedMinsAgo: 5 })).toBe(false);
  });

  it("ignores a sync that never started", async () => {
    expect(await seedAndSelect({ startedMinsAgo: null })).toBe(false);
  });

  it("ignores a connection already flagged for recovery", async () => {
    expect(
      await seedAndSelect({ startedMinsAgo: 60, recoveryPending: true })
    ).toBe(false);
  });

  it("ignores a connection whose auth is broken (needs re-auth)", async () => {
    expect(await seedAndSelect({ startedMinsAgo: 60, needsReauth: true })).toBe(
      false
    );
  });

  it("ignores a sync on an archived twist instance", async () => {
    expect(await seedAndSelect({ startedMinsAgo: 60, archived: true })).toBe(
      false
    );
  });

  it("ignores a sync on a suspended twist instance", async () => {
    expect(await seedAndSelect({ startedMinsAgo: 60, suspended: true })).toBe(
      false
    );
  });

  it("ignores a sync on a draft twist instance", async () => {
    expect(await seedAndSelect({ startedMinsAgo: 60, draft: true })).toBe(false);
  });
});

/**
 * Seed one orphaned stuck connection with `attempts` prior recovery attempts,
 * run `act` against it (the unit under test), read the row back, and roll back.
 */
async function seedAndAct(
  attempts: number,
  act: (trx: Kysely<DB>, candidate: StuckSyncCandidate) => Promise<unknown>
): Promise<{ recoveryPending: boolean; needsReauth: boolean; attempts: number }> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const twistInstanceId = randomUUID();
  const userId = randomUUID();
  const provider = "linear";
  let row = { recoveryPending: false, needsReauth: false, attempts: 0 };
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      // Real user row: flagForRetry/giveUpStuckSync run their UPDATE under the
      // default replication role, which re-checks the user_id FK.
      await sql`INSERT INTO "user" (id, email)
        VALUES (${userId}::uuid, ${`stuck-sync-${userId}@example.test`})`.execute(
        trx
      );
      await sql`INSERT INTO twist_instance (id, twist_id, owner_id, name, draft)
        VALUES (${twistInstanceId}::uuid, 1, ${userId}::uuid, 'Linear', false)`.execute(
        trx
      );
      await sql`INSERT INTO twist_instance_connection
          (twist_instance_id, user_id, provider, actor_id,
           initial_sync_started_at, recovery_pending, needs_reauth_at,
           initial_sync_attempts)
        VALUES (${twistInstanceId}::uuid, ${userId}::uuid, ${provider}, ${randomUUID()}::uuid,
          now() - interval '60 minutes', false, null, ${attempts})`.execute(trx);
      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      await act(trx, {
        twistInstanceId,
        userId,
        provider,
        initialSyncAttempts: attempts,
      });

      const res = await sql<{
        recovery_pending: boolean;
        needs_reauth_at: Date | null;
        initial_sync_attempts: number;
      }>`SELECT recovery_pending, needs_reauth_at, initial_sync_attempts
         FROM twist_instance_connection
         WHERE twist_instance_id = ${twistInstanceId}::uuid`.execute(trx);
      const r = res.rows[0];
      row = {
        recoveryPending: r.recovery_pending,
        needsReauth: r.needs_reauth_at !== null,
        attempts: r.initial_sync_attempts,
      };
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
  return row;
}

describe("recoveryAction", () => {
  it("retries while under the attempt cap", () => {
    expect(recoveryAction(0)).toBe("retry");
    expect(recoveryAction(MAX_INITIAL_SYNC_ATTEMPTS - 1)).toBe("retry");
  });

  it("gives up at or beyond the attempt cap", () => {
    expect(recoveryAction(MAX_INITIAL_SYNC_ATTEMPTS)).toBe("give_up");
    expect(recoveryAction(MAX_INITIAL_SYNC_ATTEMPTS + 5)).toBe("give_up");
  });
});

describe.skipIf(!DATABASE_URL)("flagForRetry", () => {
  it("flags recovery_pending and increments the attempt counter", async () => {
    const row = await seedAndAct(1, (trx, c) => flagForRetry(trx, c));
    expect(row.recoveryPending).toBe(true);
    expect(row.attempts).toBe(2);
    expect(row.needsReauth).toBe(false);
  });
});

describe.skipIf(!DATABASE_URL)("giveUpStuckSync", () => {
  it("flags needs_reauth and does not request another recovery", async () => {
    const row = await seedAndAct(MAX_INITIAL_SYNC_ATTEMPTS, (trx, c) =>
      giveUpStuckSync(trx, c)
    );
    expect(row.needsReauth).toBe(true);
    expect(row.recoveryPending).toBe(false);
  });
});

describe.skipIf(!DATABASE_URL)("selectStuckSyncCandidates attempt counter", () => {
  it("carries initial_sync_attempts on the candidate", async () => {
    const captured = await seedAndAct(2, async (trx, c) => {
      const rows = await selectStuckSyncCandidates(
        trx,
        new Date(Date.now() - 30 * 60 * 1000)
      );
      const mine = rows.find((r) => r.twistInstanceId === c.twistInstanceId);
      expect(mine?.initialSyncAttempts).toBe(2);
    });
    // seedAndAct returns the row read-back; the assertion above is the point.
    expect(captured.attempts).toBe(2);
  });
});
