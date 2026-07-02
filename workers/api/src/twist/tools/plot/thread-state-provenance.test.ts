import { randomUUID } from "node:crypto";
import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";
import { createDb, type DB } from "../../../db";
import { rpcUser } from "../../../rpc";

const DATABASE_URL = process.env.DATABASE_URL;

/**
 * `seq`/`read_seq`/`todo_seq` are `pg_current_xact_id()`, which is fixed for
 * the lifetime of one Postgres transaction (verified manually: two SELECTs
 * inside one BEGIN...COMMIT return the same value; two separate autocommitted
 * statements return distinct, increasing values). Detecting "did this
 * dimension's cursor bump" therefore requires each write under test to run in
 * its own committed transaction -- bump-vs-preserve would look identical
 * within a single transaction. So, unlike the single-transaction+ROLLBACK
 * harness used elsewhere in this package (see integrations-thread-read.test.ts),
 * this file issues each statement directly against `db` (its own implicit,
 * autocommitted transaction) and cleans up explicitly afterward.
 */
async function withThread(
  fn: (db: Kysely<DB>, ids: { userId: string; threadId: string }) => Promise<void>,
) {
  const db = createDb({ DATABASE_URL } as never);
  const userId = randomUUID();
  const threadId = randomUUID();
  try {
    await sql`INSERT INTO public."user" (id, email) VALUES (${userId}, ${`${userId}@example.com`})`.execute(db);
    await sql`INSERT INTO public.thread (id, created_by, draft) VALUES (${threadId}, ${userId}, TRUE)`.execute(db);
    await fn(db, { userId, threadId });
  } finally {
    await sql`DELETE FROM public.thread WHERE id = ${threadId}`.execute(db);
    await sql`DELETE FROM public."user" WHERE id = ${userId}`.execute(db);
    await db.destroy();
  }
}

async function insertState(db: Kysely<DB>, userId: string, threadId: string) {
  await sql`INSERT INTO public.thread_state (user_id, thread_id, active, read_at)
            VALUES (${userId}, ${threadId}, false, now())`.execute(db);
}

async function readRow(db: Kysely<DB>, userId: string, threadId: string) {
  const r = await sql<{
    seq: string; read_seq: string | null; todo_seq: string | null;
    read_source: string | null; todo_source: string | null; read_at: Date | null;
  }>`SELECT seq::text, read_seq::text, todo_seq::text,
            read_source::text, todo_source::text, read_at
       FROM public.thread_state WHERE user_id=${userId} AND thread_id=${threadId}`.execute(db);
  return r.rows[0];
}

describe.skipIf(!DATABASE_URL)("thread_state per-dimension trigger", () => {
  it("read change bumps read_seq only; todo change bumps todo_seq only", async () => {
    await withThread(async (db, { userId, threadId }) => {
      await insertState(db, userId, threadId);
      const before = await readRow(db, userId, threadId);

      // Change read_at only (its own committed transaction).
      await sql`UPDATE public.thread_state SET read_at = NULL
                WHERE user_id=${userId} AND thread_id=${threadId}`.execute(db);
      const afterRead = await readRow(db, userId, threadId);
      expect(afterRead.read_seq).not.toBe(before.read_seq);
      expect(afterRead.todo_seq).toBe(before.todo_seq);

      // Change active only (its own committed transaction).
      await sql`UPDATE public.thread_state SET active = TRUE
                WHERE user_id=${userId} AND thread_id=${threadId}`.execute(db);
      const afterTodo = await readRow(db, userId, threadId);
      expect(afterTodo.todo_seq).not.toBe(afterRead.todo_seq);
      expect(afterTodo.read_seq).toBe(afterRead.read_seq);
    });
  });

  it("stamps provenance from the GUC on the changed dimension only", async () => {
    await withThread(async (db, { userId, threadId }) => {
      await insertState(db, userId, threadId);
      const inst = randomUUID();
      // set_config + UPDATE must share one transaction so the trigger sees the
      // transaction-local GUC value set by set_config(..., true).
      await db.transaction().execute(async (trx) => {
        await sql`SELECT set_config('plot.write_source_twist_instance', ${inst}, true)`.execute(trx);
        await sql`UPDATE public.thread_state SET read_at = NULL
                  WHERE user_id=${userId} AND thread_id=${threadId}`.execute(trx);
      });
      const row = await readRow(db, userId, threadId);
      expect(row.read_source).toBe(inst);
      expect(row.todo_source).toBeNull(); // todo dimension untouched → no provenance
    });
  });
});

describe.skipIf(!DATABASE_URL)("provenance via RPC parameter (autocommit)", () => {
  it("clear_thread_state stamps read_source from p_write_source", async () => {
    const db = createDb({ DATABASE_URL } as never);
    const userId = randomUUID();
    const threadId = randomUUID();
    const inst = randomUUID();
    try {
      await sql`INSERT INTO public."user" (id, email) VALUES (${userId}, ${`${userId}@example.com`})`.execute(db);
      // accept_invitations_after_user_created auto-provisions a root
      // ("Everything") priority for every new user; reuse it rather than
      // inserting a second root (validate_priority_root_trigger only
      // allows one root per user).
      const p = await sql<{ id: string }>`
        SELECT id FROM public.priority
        WHERE user_id = ${userId} AND nlevel(path) = 1`.execute(db);
      const priorityId = p.rows[0]?.id;
      await sql`INSERT INTO public.thread (id, created_by, draft) VALUES (${threadId}, ${userId}, TRUE)`.execute(db);
      await sql`INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
                VALUES (${threadId}, ${userId}, ${priorityId})`.execute(db);

      await rpcUser(db, "clear_thread_state", {
        user_id: userId,
        p_thread_id: threadId,
        p_write_source: inst,
      });

      const r = await sql<{ read_source: string | null }>`
        SELECT read_source::text FROM public.thread_state
        WHERE user_id=${userId} AND thread_id=${threadId}`.execute(db);
      expect(r.rows[0]?.read_source).toBe(inst);
    } finally {
      await sql`DELETE FROM public.thread WHERE id=${threadId}`.execute(db);
      await sql`DELETE FROM public."user" WHERE id=${userId}`.execute(db);
      await db.destroy();
    }
  });
});
