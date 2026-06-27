import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { ThreadAccess } from "@plotday/twister/tools/plot";

import { createDb, type DB } from "../../../db";
import type { Bindings } from "../../../env";
import { Plot } from "./index";

const DATABASE_URL = process.env.DATABASE_URL;

function makeEnv(): Bindings {
  const usageStub = {
    init: async () => undefined,
    track: () => {},
    getUsage: async () => ({ tokens: 0, cost: 0 }),
  };
  return {
    AI: { run: async () => ({ data: [] }) },
    AI_GATEWAY_ACCOUNT_ID: "test-account",
    AI_GATEWAY_ID: "test-gateway",
    AI_GATEWAY_TOKEN: "test-token",
    ANTHROPIC_API_KEY: "test-anthropic-key",
    USAGE: {
      idFromName: () => "test-usage-id",
      get: () => usageStub,
    },
  } as unknown as Bindings;
}

async function seedUserRow(db: Kysely<DB>): Promise<string> {
  const userId = randomUUID();
  const email = `xu-${userId}@example.test`;
  await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(db);
  await sql`SELECT public.upsert_user_contact(${userId}::uuid, ${email}, 'Owner', NULL)`.execute(db);
  await sql`INSERT INTO ai_preference (user_id, builtin_ai_disabled) VALUES (${userId}::uuid, TRUE)`.execute(db);
  return userId;
}

function seedInstance(db: Kysely<DB>, twistId: string, userId: string) {
  return (async () => {
    const twistInstanceId = randomUUID();
    await sql`
      INSERT INTO twist_instance (id, twist_id, owner_id, name)
      VALUES (${twistInstanceId}::uuid, ${twistId}, ${userId}::uuid, 'Test Connector')
    `.execute(db);
    const plot = new Plot({
      db,
      twistInstanceId,
      options: { thread: { access: ThreadAccess.Create } },
      env: makeEnv(),
    });
    return { userId, twistInstanceId, plot };
  })();
}

/**
 * Seed TWO users who each own a connector twist_instance pointing at the SAME
 * public twist row. Their saveLinks dedup onto one shared thread via
 * (twist_id, key) — the cross-user shared-thread scenario (e.g. two Plot users
 * both syncing the same GitHub repo). Cleans up both users' threads/filings
 * afterward (twist/publisher rows are left in the disposable worktree DB).
 */
async function withTwoConnectorPlots<T>(
  fn: (
    db: Kysely<DB>,
    a: { userId: string; twistInstanceId: string; plot: Plot },
    b: { userId: string; twistInstanceId: string; plot: Plot },
  ) => Promise<T>,
): Promise<T> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userAId = await seedUserRow(db);
  const userBId = await seedUserRow(db);

  // One shared public twist row (with a publisher) — both instances derive the
  // same twist_id, so upsert_thread dedups their threads on (twist_id, key).
  const suffix = randomUUID().slice(0, 8);
  const publisher = await sql<{ id: string }>`
    INSERT INTO publisher (name, created_by, can_publish_public)
    VALUES (${`Test Publisher ${suffix}`}, ${userAId}::uuid, TRUE)
    RETURNING id
  `.execute(db);
  const twistPackageId = randomUUID();
  const twist = await sql<{ id: string }>`
    INSERT INTO twist (environment, name, version, twist_package_id, handle, publisher_id)
    VALUES ('public', ${`Shared Connector ${suffix}`}, '0.0.0', ${twistPackageId}::uuid, ${`shared-connector-${suffix}`}, ${publisher.rows[0].id})
    RETURNING id
  `.execute(db);
  const twistId = twist.rows[0].id;

  const a = await seedInstance(db, twistId, userAId);
  const b = await seedInstance(db, twistId, userBId);
  try {
    return await fn(db, a, b);
  } finally {
    for (const u of [a, b]) {
      try {
        await sql`DELETE FROM thread WHERE created_by = ${u.twistInstanceId}::uuid OR id IN (SELECT thread_id FROM thread_priority WHERE user_id = ${u.userId}::uuid)`.execute(db);
      } catch {
        /* ignore */
      }
      try {
        await sql`DELETE FROM "user" WHERE id = ${u.userId}::uuid`.execute(db);
      } catch {
        /* ignore */
      }
    }
    await db.destroy();
  }
}

describe.skipIf(!DATABASE_URL)("cross-user connector thread attestation", () => {
  it("admits the second syncer of a shared connector thread (own connector attests)", async () => {
    await withTwoConnectorPlots(async (db, a, b) => {
      // An external author (a PR author) — neither connection owner is a
      // participant, so the shared thread's contacts never list user B.
      const author = {
        email: `pr-author-${randomUUID()}@example.test`,
        name: "PR Author",
      };
      const source = `github:pr:plotday/core/${randomUUID()}`;

      // User A syncs first → creates the shared thread and files into it.
      const threadIdA = await a.plot.createLink({
        title: "Shared PR",
        type: "pull_request",
        source,
        author,
        unread: false,
      } as never);

      // User B's own connector syncs the same PR. Before the fix this raised
      // "User does not have access to this thread" from upsert_link (B had no
      // thread_priority because the attestation check only admits a 2nd user
      // already present in thread.contacts). B's own connector synced it, so B
      // must now be admitted.
      const threadIdB = await b.plot.createLink({
        title: "Shared PR",
        type: "pull_request",
        source,
        author,
        unread: false,
      } as never);

      // Both converge on the SAME shared thread.
      expect(threadIdB).toBe(threadIdA);

      // B now has a (non-revoked) thread_priority filing on the shared thread.
      const bFiling = await db
        .selectFrom("thread_priority")
        .select(["priority_id", "revoked_at"])
        .where("thread_id", "=", threadIdA as string)
        .where("user_id", "=", b.userId)
        .executeTakeFirst();
      expect(bFiling).toBeDefined();
      expect(bFiling?.revoked_at).toBeNull();

      // And B's link write succeeded (no rollback) — the canonical link exists
      // pointing at the shared thread.
      const bLink = await db
        .selectFrom("link")
        .select(["id", "thread_id"])
        .where("source", "=", source)
        .where("created_by", "=", b.twistInstanceId)
        .executeTakeFirst();
      expect(bLink?.thread_id).toBe(threadIdA);

      // B's primary contact landed in thread.contacts so user.thread surfaces it
      // for B (visibility requires contacts ∩ user_contact_ids, not just a filing).
      const thread = await db
        .selectFrom("thread")
        .select("contacts")
        .where("id", "=", threadIdA as string)
        .executeTakeFirst();
      const bContacts = await db
        .selectFrom("user_contact")
        .select("contact_id")
        .where("user_id", "=", b.userId)
        .where("linked", "=", true)
        .execute();
      const bContactIds = bContacts.map((c) => c.contact_id);
      expect((thread?.contacts ?? []).some((c) => bContactIds.includes(c))).toBe(
        true,
      );
    });
  });
});
