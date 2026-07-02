import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../../db";
import { rpcUser } from "../../rpc";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

type Seed = { ownerId: string; instId: string; threadId: string };

/**
 * Seed a connector-owned thread: a user (auto-provisioned root priority via
 * accept_invitations_after_user_created), a twist_instance owned by that user
 * (twist_id 1 = the built-in "Plot" system twist seeded by 99-data — no need
 * to insert a twist row), a thread whose created_by is that instance, and a
 * thread_priority filing so clear_thread_state/upsert_thread_state accept
 * writes for this thread.
 */
async function seed(db: Kysely<DB>): Promise<Seed> {
  const ownerId = randomUUID();
  const instId = randomUUID();
  const threadId = randomUUID();

  await sql`INSERT INTO public."user" (id, email) VALUES (${ownerId}, ${`${ownerId}@example.test`})`.execute(db);
  const p = await sql<{ id: string }>`
    SELECT id FROM public.priority
    WHERE user_id = ${ownerId} AND nlevel(path) = 1`.execute(db);
  const priorityId = p.rows[0]?.id;
  await sql`INSERT INTO public.twist_instance (id, twist_id, owner_id, name)
            VALUES (${instId}, 1, ${ownerId}, 'test instance')`.execute(db);
  // Backdate created_at (set_twist_instance_created_at fires BEFORE INSERT
  // and stamps now() unconditionally, so this must be a separate UPDATE --
  // the trigger only listens for INSERT). Both dispatch views require
  // thread_state.updated_at > twist_instance.created_at, and inside a single
  // transaction (the withSeed rollback harness) now() is frozen for the
  // whole transaction -- without backdating, the instance and every
  // thread_state write in the same transaction would tie on now() and the
  // view would spuriously exclude the row regardless of the echo filter.
  await sql`UPDATE public.twist_instance SET created_at = now() - interval '1 hour'
            WHERE id = ${instId}`.execute(db);
  await sql`INSERT INTO public.thread (id, created_by, title) VALUES (${threadId}, ${instId}, 'test thread')`.execute(db);
  await sql`INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
            VALUES (${threadId}, ${ownerId}, ${priorityId})`.execute(db);

  return { ownerId, instId, threadId };
}

async function cleanup(db: Kysely<DB>, { ownerId, threadId }: Seed) {
  // thread_state/thread_priority/link/etc cascade from thread; priority/
  // twist_instance/contact cascade from user.
  await sql`DELETE FROM public.thread WHERE id = ${threadId}`.execute(db);
  await sql`DELETE FROM public."user" WHERE id = ${ownerId}`.execute(db);
}

async function readViewSeq(db: Kysely<DB>, instId: string, threadId: string) {
  const r = await sql<{ seq: string }>`
    SELECT seq::text FROM public.twist_instance_thread_read
    WHERE twist_instance_id = ${instId} AND thread_id = ${threadId}`.execute(db);
  return r.rows[0]?.seq ?? null;
}

async function scheduleViewSeq(db: Kysely<DB>, instId: string, threadId: string) {
  const r = await sql<{ seq: string }>`
    SELECT seq::text FROM public.twist_instance_thread_schedule
    WHERE twist_instance_id = ${instId} AND thread_id = ${threadId}`.execute(db);
  return r.rows[0]?.seq ?? null;
}

/**
 * Rollback-transaction harness for the echo-filter assertions below: they only
 * check row presence/absence and read_source/todo_source column values (set
 * directly via the p_write_source RPC parameter, not via xact-scoped seq
 * comparisons), so a single transaction + ROLLBACK is safe and keeps the DB
 * clean without explicit teardown.
 */
async function withSeed(fn: (trx: Kysely<DB>, s: Seed) => Promise<void>) {
  const db = createDb({ DATABASE_URL } as never);
  try {
    await db.transaction().execute(async (trx) => {
      await fn(trx, await seed(trx));
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
}

/**
 * `seq`/`read_seq`/`todo_seq` are all `pg_current_xact_id()`, which is fixed
 * for the lifetime of one Postgres transaction (see
 * plot/thread-state-provenance.test.ts for the manually-verified rationale).
 * Proving "this dimension's cursor advanced but the other one didn't" across
 * two writes therefore requires each write to run in its OWN committed
 * transaction -- inside a single transaction (e.g. the withSeed+ROLLBACK
 * harness above) both writes would get the identical xid and the assertion
 * could never distinguish advance from no-op. So this harness seeds via
 * autocommitted statements directly against `db` and cleans up explicitly.
 */
async function withCommittedSeed(fn: (db: Kysely<DB>, s: Seed) => Promise<void>) {
  const db = createDb({ DATABASE_URL } as never);
  const s = await seed(db);
  try {
    await fn(db, s);
  } finally {
    await cleanup(db, s);
    await db.destroy();
  }
}

describe.skipIf(!DATABASE_URL)("write-back dispatch views", () => {
  it("a todo change does NOT advance the read view's seq (per-dimension)", async () => {
    await withCommittedSeed(async (db, { instId, threadId, ownerId }) => {
      // Establish a Plot-side read (source NULL -> visible in read view).
      // Its own committed transaction (autocommit).
      await rpcUser(db, "clear_thread_state", { user_id: ownerId, p_thread_id: threadId });
      const readSeqBefore = await readViewSeq(db, instId, threadId);
      const schedSeqBefore = await scheduleViewSeq(db, instId, threadId);
      expect(readSeqBefore).not.toBeNull();

      // A todo write (active=true) -- Plot-side (no source). Its own
      // committed transaction (autocommit), distinct xact id from the write
      // above.
      await rpcUser(db, "upsert_thread_state", {
        user_id: ownerId,
        p_thread_id: threadId,
        p_active: true,
        p_set_active: true,
      });

      expect(await readViewSeq(db, instId, threadId)).toBe(readSeqBefore); // unchanged
      expect(await scheduleViewSeq(db, instId, threadId)).not.toBe(schedSeqBefore); // advanced
    });
  });

  it("a connector-provenance read is suppressed from the read view (echo)", async () => {
    await withSeed(async (trx, { instId, threadId, ownerId }) => {
      // Connector marks read inbound (source = instId) -> must NOT appear.
      await rpcUser(trx, "clear_thread_state", {
        user_id: ownerId,
        p_thread_id: threadId,
        p_write_source: instId,
      });
      expect(await readViewSeq(trx, instId, threadId)).toBeNull();
    });
  });

  it("a Plot-side read IS emitted by the read view", async () => {
    await withSeed(async (trx, { instId, threadId, ownerId }) => {
      await rpcUser(trx, "clear_thread_state", { user_id: ownerId, p_thread_id: threadId });
      expect(await readViewSeq(trx, instId, threadId)).not.toBeNull();
    });
  });
});
