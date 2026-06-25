import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../../db";
import type { Bindings } from "../../env";
import { Integrations } from "./integrations";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

type DispatchResult = Array<{ sourceMethod?: string; args?: unknown[] }>;

type IntegrationsDispatch = {
  dispatch: (item: unknown) => Promise<DispatchResult>;
};

/**
 * Build a minimally-wired Integrations tool against a real Kysely<DB>. The
 * `thread_read` dispatch path requires `sourceProvider` (the connector-only
 * gate) and only reads from `this.db`, so no DO stubs are needed.
 */
function makeTool(db: Kysely<DB>, twistInstanceId: string): IntegrationsDispatch {
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
    sourceProvider: { provider: "test" },
  });

  return tool as unknown as IntegrationsDispatch;
}

type SeedResult = {
  threadId: string;
  connectorId: string;
  ownerId: string;
  ownerContactId: string;
  gmailThreadId: string;
  channelId: string;
};

/**
 * Seed a connector-owned thread: an owner user with a linked primary contact, a
 * `twist_instance` owned by that user, a thread whose `created_by` is the
 * connector instance, and a link created by that same connector (so the dispatch
 * handler recognizes the thread as owned by it). The link's meta carries the
 * external `threadId` the connector needs for write-back. Triggers/FKs are
 * disabled during seeding; everything is rolled back afterward.
 */
async function withSeed(
  body: (trx: Kysely<DB>, seed: SeedResult) => Promise<void>,
): Promise<void> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const ownerId = randomUUID();
  const connectorId = randomUUID();
  const ownerContactId = randomUUID();
  const threadId = randomUUID();
  const linkId = randomUUID();
  const gmailThreadId = `gmail-thread-${randomUUID()}`;
  const channelId = `google:${randomUUID()}`;
  const email = `tr-${ownerId}@example.test`;

  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      await sql`INSERT INTO "user" (id, email) VALUES (${ownerId}::uuid, ${email})`.execute(trx);
      await sql`INSERT INTO contact (id, user_id, "primary", name, email)
        VALUES (${ownerContactId}::uuid, ${ownerId}::uuid, true, 'Owner', ${email})`.execute(trx);
      await sql`INSERT INTO user_contact (user_id, contact_id, linked, "primary")
        VALUES (${ownerId}::uuid, ${ownerContactId}::uuid, true, true)`.execute(trx);

      // The connector instance, owned by the user above.
      await sql`INSERT INTO twist_instance (id, twist_id, owner_id, name)
        VALUES (${connectorId}::uuid, 1, ${ownerId}::uuid, 'Test connector')`.execute(trx);

      // Thread + link both created by the connector twist_instance. The link's
      // meta holds the external Gmail thread id; channel_id holds the channel.
      await sql`INSERT INTO thread (id, created_by, title, contacts)
        VALUES (${threadId}::uuid, ${connectorId}::uuid, 'Email thread',
                ARRAY[${ownerContactId}::uuid]::uuid[])`.execute(trx);
      await sql`INSERT INTO link (id, thread_id, created_by, type, source, channel_id, meta)
        VALUES (${linkId}::uuid, ${threadId}::uuid, ${connectorId}::uuid, 'email',
                'google:gmail:1', ${channelId},
                ${sql.lit(JSON.stringify({ threadId: gmailThreadId }))}::jsonb)`.execute(trx);

      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      await body(trx, {
        threadId,
        connectorId,
        ownerId,
        ownerContactId,
        gmailThreadId,
        channelId,
      });
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
}

describe.skipIf(!DATABASE_URL)("Integrations.dispatch thread_read", () => {
  it("dispatches onThreadRead(unread=false) for the owner's read on a connector-owned thread", async () => {
    await withSeed(async (trx, { threadId, connectorId, ownerId, ownerContactId, gmailThreadId, channelId }) => {
      const tool = makeTool(trx, connectorId);

      const result = await tool.dispatch({
        itemType: "thread_read",
        item: { thread_id: threadId, user_id: ownerId, read_at: new Date().toISOString() },
      });

      expect(result).toHaveLength(1);
      expect(result[0].sourceMethod).toBe("onThreadRead");

      const [thread, actor, unread] = result[0].args as [
        { id: string; meta: { threadId?: string; channelId?: string | null } },
        { id: string },
        boolean,
      ];

      expect(thread.id).toBe(threadId);
      // The connector needs the external thread id + channel for write-back.
      expect(thread.meta.threadId).toBe(gmailThreadId);
      expect(thread.meta.channelId).toBe(channelId);
      // read_at set => the thread is now read, so unread=false.
      expect(unread).toBe(false);
      // Actor resolves to the owner's primary linked contact.
      expect(actor.id).toBe(ownerContactId);
    });
  });

  it("dispatches onThreadRead(unread=true) when read_at is cleared", async () => {
    await withSeed(async (trx, { threadId, connectorId, ownerId }) => {
      const tool = makeTool(trx, connectorId);

      const result = await tool.dispatch({
        itemType: "thread_read",
        item: { thread_id: threadId, user_id: ownerId, read_at: null },
      });

      expect(result).toHaveLength(1);
      expect(result[0].sourceMethod).toBe("onThreadRead");
      const [, , unread] = result[0].args as [unknown, unknown, boolean];
      expect(unread).toBe(true);
    });
  });

  it("does not dispatch for a thread owned by a different twist", async () => {
    await withSeed(async (trx, { threadId, ownerId }) => {
      // A different connector instance — it owns no link on this thread.
      const tool = makeTool(trx, randomUUID());

      const result = await tool.dispatch({
        itemType: "thread_read",
        item: { thread_id: threadId, user_id: ownerId, read_at: new Date().toISOString() },
      });

      expect(result).toEqual([]);
    });
  });

  it("does not write back another user's read to the connection owner's account", async () => {
    await withSeed(async (trx, { threadId, connectorId }) => {
      const tool = makeTool(trx, connectorId);

      // A non-owner user read the shared thread — must NOT mark the owner's
      // external account read.
      const result = await tool.dispatch({
        itemType: "thread_read",
        item: { thread_id: threadId, user_id: randomUUID(), read_at: new Date().toISOString() },
      });

      expect(result).toEqual([]);
    });
  });
});
