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
 * `thread_contacts` dispatch path requires `sourceProvider` to be set (it's the
 * connector-only gate) and only reads from `this.db`, so no DO stubs are needed.
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
  contactA: string;
  contactB: string;
  contactC: string;
};

/**
 * Seed a connector-owned thread: a user with a linked primary contact, two more
 * contacts, a thread whose `created_by` is a connector twist_instance, and a
 * link created by that same connector (so the dispatch handler recognizes the
 * thread as owned by it). Triggers are disabled during seeding; everything is
 * rolled back afterward.
 */
async function withSeed(
  body: (trx: Kysely<DB>, seed: SeedResult) => Promise<void>,
): Promise<void> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const connectorId = randomUUID();
  const contactA = randomUUID();
  const contactB = randomUUID();
  const contactC = randomUUID();
  const threadId = randomUUID();
  const linkId = randomUUID();
  const email = `cc-${userId}@example.test`;

  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(trx);
      await sql`INSERT INTO contact (id, user_id, "primary", name, email)
        VALUES (${contactA}::uuid, ${userId}::uuid, true, 'Alice', ${`alice-${userId}@example.test`})`.execute(trx);
      await sql`INSERT INTO contact (id, name, email)
        VALUES (${contactB}::uuid, 'Bob', ${`bob-${userId}@example.test`})`.execute(trx);
      await sql`INSERT INTO contact (id, name, email)
        VALUES (${contactC}::uuid, 'Carol', ${`carol-${userId}@example.test`})`.execute(trx);

      // Thread + link both created by the connector twist_instance.
      await sql`INSERT INTO thread (id, created_by, title, contacts)
        VALUES (${threadId}::uuid, ${connectorId}::uuid, 'Group chat',
                ARRAY[${contactA}::uuid, ${contactC}::uuid]::uuid[])`.execute(trx);
      await sql`INSERT INTO link (id, thread_id, created_by, type, source)
        VALUES (${linkId}::uuid, ${threadId}::uuid, ${connectorId}::uuid, 'chat', 'test:chat:1')`.execute(trx);

      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      await body(trx, { threadId, connectorId, contactA, contactB, contactC });
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
}

describe.skipIf(!DATABASE_URL)("Integrations.dispatch thread_contacts", () => {
  it("dispatches onContactsChanged with resolved contacts for a connector-owned thread", async () => {
    await withSeed(async (trx, { threadId, connectorId, contactA, contactB, contactC }) => {
      const tool = makeTool(trx, connectorId);

      const result = await tool.dispatch({
        itemType: "thread_contacts",
        item: {
          thread_id: threadId,
          added: [{ contactId: contactC, role: null }],
          removed: [{ contactId: contactB, role: "to" }],
          changed: [{ contactId: contactA, from: "to", to: "cc" }],
        },
      });

      expect(result).toHaveLength(1);
      expect(result[0].sourceMethod).toBe("onContactsChanged");

      const [thread, changes] = result[0].args as [
        { id: string },
        {
          added: Array<{ contact: { id: string; name: string | null; email: string | null }; role: string | null }>;
          removed: Array<{ contact: { id: string }; role: string | null }>;
          changed: Array<{ contact: { id: string }; from: string | null; to: string | null }>;
        },
      ];

      expect(thread.id).toBe(threadId);

      expect(changes.added).toEqual([
        { contact: { id: contactC, name: "Carol", email: expect.stringContaining("carol-") }, role: null },
      ]);
      expect(changes.removed).toEqual([
        { contact: { id: contactB, name: "Bob", email: expect.stringContaining("bob-") }, role: "to" },
      ]);
      expect(changes.changed).toEqual([
        { contact: { id: contactA, name: "Alice", email: expect.stringContaining("alice-") }, from: "to", to: "cc" },
      ]);
    });
  });

  it("does not dispatch for a thread owned by a different twist", async () => {
    await withSeed(async (trx, { threadId, contactC }) => {
      // A different connector instance — it owns no link on this thread.
      const tool = makeTool(trx, randomUUID());

      const result = await tool.dispatch({
        itemType: "thread_contacts",
        item: {
          thread_id: threadId,
          added: [{ contactId: contactC, role: null }],
          removed: [],
          changed: [],
        },
      });

      expect(result).toEqual([]);
    });
  });

  it("does not dispatch when the diff is empty", async () => {
    await withSeed(async (trx, { threadId, connectorId }) => {
      const tool = makeTool(trx, connectorId);

      const result = await tool.dispatch({
        itemType: "thread_contacts",
        item: { thread_id: threadId, added: [], removed: [], changed: [] },
      });

      expect(result).toEqual([]);
    });
  });
});
