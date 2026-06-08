import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../../../db";
import type { Bindings } from "../../../env";
import { rpcUser } from "../../../rpc";

const DATABASE_URL = process.env.DATABASE_URL;

class Rollback extends Error {}

async function withThread<T>(
  fn: (trx: Kysely<DB>, ctx: { userId: string; threadId: string }) => Promise<T>,
): Promise<T> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const threadId = randomUUID();
  const email = `lk-${userId}@example.test`;
  let captured: T;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(trx);
      await sql`SELECT public.upsert_user_contact(${userId}::uuid, ${email}, 'Owner', NULL)`.execute(trx);
      const root = await sql<{ id: string }>`
        SELECT id FROM priority WHERE user_id = ${userId}::uuid ORDER BY path LIMIT 1
      `.execute(trx);
      const priorityId = root.rows[0].id;
      await sql`INSERT INTO thread (id, created_by, title) VALUES (${threadId}::uuid, ${userId}::uuid, 'Link test thread')`.execute(trx);
      await sql`
        INSERT INTO thread_priority (thread_id, user_id, priority_id)
        VALUES (${threadId}::uuid, ${userId}::uuid, ${priorityId}::uuid)
      `.execute(trx);
      captured = await fn(trx, { userId, threadId });
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
  return captured!;
}

describe.skipIf(!DATABASE_URL)("upsert_link priority + note_scoped", () => {
  it("persists priority and note_scoped from p_defaults on insert", async () => {
    const row = await withThread(async (trx, { userId, threadId }) => {
      return rpcUser(trx, "upsert_link", {
        user_id: userId,
        p_link: { source: `test:${randomUUID()}` },
        p_defaults: { thread_id: threadId, created_by: userId, priority: 7, note_scoped: true },
      });
    });
    expect((row as any).priority).toBe(7);
    expect((row as any).note_scoped).toBe(true);
  });

  it("updates priority on re-upsert of the same source", async () => {
    const result = await withThread(async (trx, { userId, threadId }) => {
      const source = `pri:${randomUUID()}`;
      await rpcUser(trx, "upsert_link", {
        user_id: userId,
        p_link: { source, priority: 1 },
        p_defaults: { thread_id: threadId, created_by: userId },
      });
      return rpcUser(trx, "upsert_link", {
        user_id: userId,
        p_link: { source, priority: 5 },
        p_defaults: { thread_id: threadId, created_by: userId },
      });
    });
    expect((result as any).priority).toBe(5);
  });
});

describe.skipIf(!DATABASE_URL)("cross-connector source co-location", () => {
  it("finds a thread by sources overlap regardless of twist_id", async () => {
    const found = await withThread(async (trx, { userId, threadId }) => {
      const uid = `icaluid:${randomUUID()}`;
      // Connector A's link (note_scoped — e.g. Granola) carrying the shared alias.
      await rpcUser(trx, "upsert_link", {
        user_id: userId,
        p_link: { source: `granola:${randomUUID()}`, sources: [`granola:${uid}`, uid] },
        p_defaults: { thread_id: threadId, created_by: userId, note_scoped: true },
      });
      // The GLOBAL lookup createLink will run for connector B (no twist filter):
      const row = await trx
        .selectFrom("link")
        .select("link.thread_id")
        .where(sql<boolean>`link.sources && ${sql.val([uid])}::text[]`)
        .where("link.archived_at", "is", null)
        .limit(1)
        .executeTakeFirst();
      return row?.thread_id ?? null;
    });
    expect(found).not.toBeNull();
  });
});
