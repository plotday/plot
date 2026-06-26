import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it, vi } from "vitest";

import { ThreadAccess } from "@plotday/twister/tools/plot";

import { createDb, type DB } from "../../../db";
import type { Bindings } from "../../../env";
import type * as RpcModule from "../../../rpc";
import { Plot } from "./index";

const DATABASE_URL = process.env.DATABASE_URL;

// Selectively fail a single named RPC mid-save to simulate a transient write
// failure AFTER upsert_thread but at/before a later write in the same createLink.
// `failOn.fn` is consulted inside the mocked rpcUser; null = full pass-through.
const { failOn } = vi.hoisted(() => ({ failOn: { fn: null as string | null } }));

vi.mock("../../../rpc", async (importOriginal) => {
  const actual = await importOriginal<typeof RpcModule>();
  return {
    ...actual,
    rpcUser: async (db: unknown, fn: string, args: unknown) => {
      if (failOn.fn && fn === failOn.fn) {
        throw new Error(`injected ${fn} failure`);
      }
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      return (actual.rpcUser as any)(db, fn, args);
    },
  };
});

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

/**
 * Seed an owner user (linked primary contact + root priority, AI disabled) and a
 * connector twist_instance they own, run `fn` with a real Plot against the
 * disposable worktree DB (no wrapping transaction so createLink can open its
 * own), then best-effort clean up.
 */
async function withConnectorPlot<T>(
  fn: (
    plot: Plot,
    db: Kysely<DB>,
    ctx: { userId: string; twistInstanceId: string; priorityRootId: string },
  ) => Promise<T>,
): Promise<T> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const email = `la-${userId}@example.test`;
  try {
    await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(
      db,
    );
    await sql`SELECT public.upsert_user_contact(${userId}::uuid, ${email}, 'Owner', NULL)`.execute(
      db,
    );
    await sql`INSERT INTO ai_preference (user_id, builtin_ai_disabled) VALUES (${userId}::uuid, TRUE)`.execute(
      db,
    );
    const root = await sql<{ id: string }>`
      SELECT id FROM priority WHERE user_id = ${userId}::uuid ORDER BY path LIMIT 1
    `.execute(db);
    const priorityRootId = root.rows[0].id;

    const twistPackageId = randomUUID();
    const twist = await sql<{ id: string }>`
      INSERT INTO twist (environment, name, version, twist_package_id, handle, user_id)
      VALUES ('personal', 'Test Connector', '0.0.0', ${twistPackageId}::uuid, 'test-connector', ${userId}::uuid)
      RETURNING id
    `.execute(db);
    const twistId = twist.rows[0].id;

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

    return await fn(plot, db, { userId, twistInstanceId, priorityRootId });
  } finally {
    try {
      await sql`DELETE FROM thread WHERE created_by = ${userId}::uuid OR id IN (SELECT thread_id FROM thread_priority WHERE user_id = ${userId}::uuid)`.execute(
        db,
      );
    } catch {
      /* ignore */
    }
    try {
      await sql`DELETE FROM "user" WHERE id = ${userId}::uuid`.execute(db);
    } catch {
      /* ignore */
    }
    await db.destroy();
  }
}

describe.skipIf(!DATABASE_URL)("createLink atomicity", () => {
  it("commits thread + link + notes together on the happy path", async () => {
    failOn.fn = null;
    const result = await withConnectorPlot(async (plot, db, { twistInstanceId }) => {
      const source = `cal:${randomUUID()}`;
      const threadId = await plot.createLink({
        title: "Atomic happy path",
        source,
        preview: "Body text",
        notes: [{ content: "Body text" }],
      } as never);

      const thread = await db
        .selectFrom("thread")
        .select(["id", "key", "created_by"])
        .where("id", "=", threadId as string)
        .executeTakeFirst();
      const link = await db
        .selectFrom("link")
        .select(["id", "thread_id"])
        .where("source", "=", source)
        .executeTakeFirst();
      const note = await db
        .selectFrom("note")
        .select(["id", "thread_id"])
        .where("thread_id", "=", threadId as string)
        .where("archived_at", "is", null)
        .executeTakeFirst();

      return { threadId, thread, link, note, twistInstanceId, source };
    });

    // Thread, its canonical link, and its note all persisted together.
    expect(result.thread?.id).toBe(result.threadId);
    expect(result.thread?.key).toBe(result.source);
    expect(result.thread?.created_by).toBe(result.twistInstanceId);
    expect(result.link?.thread_id).toBe(result.threadId);
    expect(result.note?.thread_id).toBe(result.threadId);
  });

  it("rolls back the thread when a write after upsert_thread fails (no orphan shell)", async () => {
    const counts = await withConnectorPlot(async (plot, db, { twistInstanceId }) => {
      const source = `cal:${randomUUID()}`;

      // Fail upsert_link — which runs AFTER upsert_thread has inserted the
      // thread row. With a non-atomic createLink the thread would commit and be
      // stranded as an orphan shell (no link → NULL feed sort key). With the
      // write wrapped in a transaction, the failure must roll the thread back.
      failOn.fn = "upsert_link";
      let threw = false;
      try {
        await plot.createLink({
          title: "Atomic rollback",
          source,
          preview: "Body text",
          notes: [{ content: "Body text" }],
        } as never);
      } catch {
        threw = true;
      } finally {
        failOn.fn = null;
      }

      const threadCount = await db
        .selectFrom("thread")
        .select(db.fn.countAll<number>().as("n"))
        .where("created_by", "=", twistInstanceId)
        .where("key", "=", source)
        .executeTakeFirstOrThrow();
      const linkCount = await db
        .selectFrom("link")
        .select(db.fn.countAll<number>().as("n"))
        .where("source", "=", source)
        .executeTakeFirstOrThrow();

      return { threw, threads: Number(threadCount.n), links: Number(linkCount.n) };
    });

    expect(counts.threw).toBe(true);
    // The thread inserted by upsert_thread must have been rolled back with the
    // failed link write — no orphan thread, no link.
    expect(counts.threads).toBe(0);
    expect(counts.links).toBe(0);
  });
});
