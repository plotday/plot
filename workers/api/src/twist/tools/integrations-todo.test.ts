import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../../db";
import type { Bindings } from "../../env";
import { Integrations } from "./integrations";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

/**
 * Type hole into the private helper under test. `applyThreadToDoForUser` is the
 * only genuinely-new server logic added alongside `NewLink.todo` in `saveLink`,
 * and `saveLink` simply resolves the connection owner and delegates to it. We
 * exercise the helper directly against a real DB so we prove the to-do effect
 * actually lands in `thread_state` / `thread_priority`.
 */
type IntegrationsTodo = {
  applyThreadToDoForUser: (
    threadId: string,
    userId: string,
    todo: boolean,
    options?: { date?: Date | string }
  ) => Promise<void>;
};

/**
 * Build a minimally-wired Integrations tool against a real Kysely<DB>. The
 * constructor only assigns fields and synthesizes a CALLBACKS DO stub (never
 * invoked by applyThreadToDoForUser). We stub getPlot so notifySyncDOs is a
 * no-op (it would otherwise reach a Durable Object namespace, which isn't
 * available under vitest).
 */
function makeTool(db: Kysely<DB>, twistInstanceId: string): IntegrationsTodo {
  const env = {
    CALLBACKS: {
      idFromName: () => ({ name: "stub" }),
      get: () => ({}),
    },
  } as unknown as Bindings;

  const tool = new Integrations({
    store: {} as never,
    env,
    ctx: { exports: {} as never },
    db,
    twistInstanceId,
    twistId: randomUUID(),
    environment: "development" as never,
    path: [],
  });

  // Replace getPlot() with a stub whose notifySyncDOs is a no-op so the helper
  // does not try to reach a Durable Object namespace.
  (tool as unknown as { getPlot: () => unknown }).getPlot = () => ({
    notifySyncDOs: async () => {},
  });

  return tool as unknown as IntegrationsTodo;
}

type SeedResult = {
  threadId: string;
  userId: string;
};

/**
 * Seed one user with a linked primary contact, a priority, a thread filed for
 * that user with `thread_priority.archived_at` set in the past, and a read
 * `thread_state` (active=false). Triggers are disabled during seeding for
 * determinism. Runs `body` (the assertions) inside the same transaction, then
 * rolls back so the DB stays clean.
 */
async function withSeed(
  seedRead: boolean,
  body: (trx: Kysely<DB>, seed: SeedResult) => Promise<void>
): Promise<void> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const contactId = randomUUID();
  const priorityId = randomUUID();
  const threadId = randomUUID();
  const email = `todo-${userId}@example.test`;

  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(trx);
      await sql`INSERT INTO contact (id, user_id, "primary", email)
        VALUES (${contactId}::uuid, ${userId}::uuid, true, ${email})`.execute(trx);
      await sql`INSERT INTO user_contact (user_id, contact_id, linked, "primary")
        VALUES (${userId}::uuid, ${contactId}::uuid, true, true)`.execute(trx);
      await sql`INSERT INTO priority (id, created_by, user_id, title, path)
        VALUES (${priorityId}::uuid, ${userId}::uuid, ${userId}::uuid, 'Inbox', 'inbox'::ltree)`.execute(trx);
      await sql`INSERT INTO thread (id, created_by, title, contacts)
        VALUES (${threadId}::uuid, ${userId}::uuid, 'Test thread', ARRAY[${contactId}::uuid]::uuid[])`.execute(trx);
      // archived_at set in the past — the to-do=true path must lift this to NULL.
      // priority_id must be non-null & not revoked so upsert_thread_state writes
      // directly rather than deferring to pending_thread_state.
      await sql`INSERT INTO thread_priority (thread_id, user_id, priority_id, archived_at)
        VALUES (${threadId}::uuid, ${userId}::uuid, ${priorityId}::uuid, now() - interval '1 day')`.execute(trx);
      // Start read & inactive. todo=true must flip active true; todo=false leaves read_at set.
      await sql`INSERT INTO thread_state (user_id, thread_id, active, read_at, importance)
        VALUES (${userId}::uuid, ${threadId}::uuid, false, ${seedRead ? sql`null` : sql`now()`}, 50)`.execute(trx);

      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      await body(trx, { threadId, userId });
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
}

describe.skipIf(!DATABASE_URL)("Integrations.applyThreadToDoForUser", () => {
  it("todo=true makes the thread active and lifts thread_priority.archived_at", async () => {
    await withSeed(true, async (trx, { threadId, userId }) => {
      const tool = makeTool(trx, randomUUID());

      await tool.applyThreadToDoForUser(threadId, userId, true);

      const state = await trx
        .selectFrom("thread_state")
        .select(["active", "read_at"])
        .where("thread_id", "=", threadId)
        .where("user_id", "=", userId)
        .executeTakeFirstOrThrow();
      expect(state.active).toBe(true);

      const tp = await trx
        .selectFrom("thread_priority")
        .select("archived_at")
        .where("thread_id", "=", threadId)
        .where("user_id", "=", userId)
        .executeTakeFirstOrThrow();
      expect(tp.archived_at).toBeNull();
    });
  });

  it("todo=false marks the thread read (sets thread_state.read_at)", async () => {
    await withSeed(true, async (trx, { threadId, userId }) => {
      const tool = makeTool(trx, randomUUID());

      await tool.applyThreadToDoForUser(threadId, userId, false);

      const state = await trx
        .selectFrom("thread_state")
        .select(["active", "read_at"])
        .where("thread_id", "=", threadId)
        .where("user_id", "=", userId)
        .executeTakeFirstOrThrow();
      expect(state.read_at).not.toBeNull();
      // todo=false must NOT activate the thread or touch the archive.
      expect(state.active).toBe(false);

      const tp = await trx
        .selectFrom("thread_priority")
        .select("archived_at")
        .where("thread_id", "=", threadId)
        .where("user_id", "=", userId)
        .executeTakeFirstOrThrow();
      expect(tp.archived_at).not.toBeNull();
    });
  });
});
