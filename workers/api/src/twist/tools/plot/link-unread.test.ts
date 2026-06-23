import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { ThreadAccess } from "@plotday/twister/tools/plot";

import { createDb, type DB } from "../../../db";
import type { Bindings } from "../../../env";
import { Plot } from "./index";

const DATABASE_URL = process.env.DATABASE_URL;

/**
 * Minimal env for a Plot. AI is disabled per-user (see harness) so no AI binding
 * is exercised; USER_SYNC is omitted (notifySyncDOs swallows its own errors when
 * the DO namespace is unavailable under vitest).
 */
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
 * connector twist_instance they own, run `fn` with a real Plot, then best-effort
 * clean up. Unlike the rollback harnesses elsewhere, this runs against the
 * (disposable) worktree DB WITHOUT a wrapping transaction: createLink's
 * unread-marking compares the note's DB `created_at` against a wall-clock
 * `syncStartedAt`, and inside a single transaction `now()` is frozen at BEGIN —
 * which is *before* that wall-clock value, so the time window would wrongly
 * exclude the note. Separate statements (production behavior) make `now()`
 * advance, so the window works.
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
  const email = `lu-${userId}@example.test`;
  try {
    await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(
      db,
    );
    await sql`SELECT public.upsert_user_contact(${userId}::uuid, ${email}, 'Owner', NULL)`.execute(
      db,
    );
    // Disable built-in AI so createNote skips the embedding step (the Workers AI
    // binding is unavailable under vitest). The unread-marking path under test is
    // independent of AI.
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
    // Best-effort cleanup (disposable worktree DB). Deleting the threads cascades
    // to note/thread_priority/thread_state; deleting the user cascades
    // twist_instance/ai_preference/user_contact.
    try {
      await sql`DELETE FROM thread WHERE id IN (SELECT thread_id FROM thread_priority WHERE user_id = ${userId}::uuid)`.execute(
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

describe.skipIf(!DATABASE_URL)("createLink unread on arrival", () => {
  it("marks a newly-arrived connector thread unread for the owner (no Done flash)", async () => {
    const row = await withConnectorPlot(async (plot, db, { userId }) => {
      // An external sender (NOT linked to the owner) authors the incoming
      // message. The owner therefore did not author it and should see it
      // unread — i.e. in the Active unread cluster, not Done.
      const senderId = randomUUID();
      await sql`
        INSERT INTO contact (id, name, email)
        VALUES (${senderId}::uuid, 'External Sender', ${`sender-${senderId}@example.test`})
      `.execute(db);

      const threadId = await plot.createLink({
        title: "Incoming email",
        source: `gmail:${randomUUID()}`,
        author: { id: senderId },
        // Explicit preview + markdown content keep the AI path out of the test.
        preview: "Hello there",
        notes: [{ content: "Hello there", author: { id: senderId } }],
      } as any);

      const res = await sql<{ unread: boolean; active: boolean }>`
        SELECT unread, active
        FROM "user".thread
        WHERE id = ${threadId}::uuid AND user_id = ${userId}::uuid
      `.execute(db);
      return res.rows[0];
    });

    // The owner just received a message they have not read.
    expect(row).toBeDefined();
    expect(row.unread).toBe(true);
    // It belongs in the bottom unread cluster of Active, not as an active to-do.
    expect(row.active).toBe(false);
  });

  it("does NOT mark the thread unread for the owner when the owner authored the only message", async () => {
    // A message the owner sent (synced back by their own connector) must not
    // resurface as unread to themselves.
    const row = await withConnectorPlot(async (plot, db, { userId }) => {
      const ownerContact = await sql<{ id: string }>`
        SELECT contact_id AS id FROM user_contact
        WHERE user_id = ${userId}::uuid AND linked = TRUE
        ORDER BY "primary" DESC NULLS LAST LIMIT 1
      `.execute(db);
      const ownerContactId = ownerContact.rows[0].id;

      const threadId = await plot.createLink({
        title: "Message I sent",
        source: `gmail:${randomUUID()}`,
        author: { id: ownerContactId },
        preview: "Sent from me",
        notes: [{ content: "Sent from me", author: { id: ownerContactId } }],
      } as any);

      const res = await sql<{ unread: boolean }>`
        SELECT unread
        FROM "user".thread
        WHERE id = ${threadId}::uuid AND user_id = ${userId}::uuid
      `.execute(db);
      return res.rows[0];
    });

    expect(row).toBeDefined();
    expect(row.unread).toBe(false);
  });

  it("does NOT mark unread for the owner when they authored the LATEST message in a multi-message sync", async () => {
    // The common full-thread ingest: a connector first sees a pre-existing
    // conversation only when the owner replies, so the whole thread — the
    // other party's earlier message AND the owner's newer reply — lands in one
    // sync batch. The owner sent the most recent message (and has, by
    // definition, read everything before it), so the thread must NOT resurface
    // as unread to them, even though an other-authored note is in the batch.
    const row = await withConnectorPlot(async (plot, db, { userId }) => {
      const ownerContact = await sql<{ id: string }>`
        SELECT contact_id AS id FROM user_contact
        WHERE user_id = ${userId}::uuid AND linked = TRUE
        ORDER BY "primary" DESC NULLS LAST LIMIT 1
      `.execute(db);
      const ownerContactId = ownerContact.rows[0].id;

      const senderId = randomUUID();
      await sql`
        INSERT INTO contact (id, name, email)
        VALUES (${senderId}::uuid, 'External Sender', ${`sender-${senderId}@example.test`})
      `.execute(db);

      const threadId = await plot.createLink({
        title: "Conversation I replied to",
        source: `gmail:${randomUUID()}`,
        author: { id: senderId },
        preview: "My reply",
        notes: [
          {
            content: "Their earlier message",
            author: { id: senderId },
            created: new Date("2026-06-22T13:00:00.000Z"),
          },
          {
            content: "My reply",
            author: { id: ownerContactId },
            created: new Date("2026-06-22T21:00:00.000Z"),
          },
        ],
      } as any);

      const res = await sql<{ unread: boolean }>`
        SELECT unread
        FROM "user".thread
        WHERE id = ${threadId}::uuid AND user_id = ${userId}::uuid
      `.execute(db);
      return res.rows[0];
    });

    expect(row).toBeDefined();
    expect(row.unread).toBe(false);
  });

  it("marks unread for the owner when someone else authored the LATEST message in a multi-message sync", async () => {
    // Mirror of the above: the owner spoke earlier but the other party's reply
    // is the most recent message. The owner has unseen content, so the thread
    // must surface as unread.
    const row = await withConnectorPlot(async (plot, db, { userId }) => {
      const ownerContact = await sql<{ id: string }>`
        SELECT contact_id AS id FROM user_contact
        WHERE user_id = ${userId}::uuid AND linked = TRUE
        ORDER BY "primary" DESC NULLS LAST LIMIT 1
      `.execute(db);
      const ownerContactId = ownerContact.rows[0].id;

      const senderId = randomUUID();
      await sql`
        INSERT INTO contact (id, name, email)
        VALUES (${senderId}::uuid, 'External Sender', ${`sender-${senderId}@example.test`})
      `.execute(db);

      const threadId = await plot.createLink({
        title: "Conversation they replied to",
        source: `gmail:${randomUUID()}`,
        author: { id: ownerContactId },
        preview: "Their reply",
        notes: [
          {
            content: "My earlier message",
            author: { id: ownerContactId },
            created: new Date("2026-06-22T13:00:00.000Z"),
          },
          {
            content: "Their reply",
            author: { id: senderId },
            created: new Date("2026-06-22T21:00:00.000Z"),
          },
        ],
      } as any);

      const res = await sql<{ unread: boolean }>`
        SELECT unread
        FROM "user".thread
        WHERE id = ${threadId}::uuid AND user_id = ${userId}::uuid
      `.execute(db);
      return res.rows[0];
    });

    expect(row).toBeDefined();
    expect(row.unread).toBe(true);
  });
});
