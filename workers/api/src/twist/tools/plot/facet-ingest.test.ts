import { randomUUID } from "node:crypto";
import { Kysely, PostgresDialect, sql } from "kysely";
import { Pool } from "pg";
import { afterAll, describe, expect, it } from "vitest";
import type { DB } from "@plotday/db";

const DATABASE_URL = process.env.DATABASE_URL;
const d = DATABASE_URL ? describe : describe.skip;

const db = DATABASE_URL
  ? new Kysely<DB>({ dialect: new PostgresDialect({ pool: new Pool({ connectionString: DATABASE_URL }) }) })
  : (null as unknown as Kysely<DB>);

class Rollback extends Error {}

afterAll(async () => {
  if (db) await db.destroy();
});

d("upsert_thread facets persistence", () => {
  it("writes p_defaults.facets onto thread.facets and preserves on re-upsert", async () => {
    const userId = randomUUID();
    const priorityId = randomUUID();
    const email = `u${userId.slice(0, 8)}@example.com`;
    const contactId = randomUUID();
    let captured: { facets: unknown } | undefined;

    try {
      await db.transaction().execute(async (trx) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(trx);
        await sql`INSERT INTO contact (id, user_id, "primary", email) VALUES (${contactId}::uuid, ${userId}::uuid, true, ${email})`.execute(trx);
        await sql`INSERT INTO user_contact (user_id, contact_id, linked, "primary")
          VALUES (${userId}::uuid, ${contactId}::uuid, true, true)`.execute(trx);
        await sql`INSERT INTO priority (id, created_by, user_id, title, path)
          VALUES (${priorityId}::uuid, ${userId}::uuid, ${userId}::uuid, 'Inbox', 'inbox'::ltree)`.execute(trx);
        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

        const facets = { format: "reading", automation: "automated", reach: "list" };

        const first = await sql<{ id: string; facets: unknown }>`
          SELECT id, facets FROM "user".upsert_thread(
            ${userId}::uuid,
            ${JSON.stringify({ title: "Newsletter" })}::jsonb,
            ${JSON.stringify({ priority_id: priorityId, facets })}::jsonb
          )`.execute(trx);
        const threadId = first.rows[0].id;
        expect(first.rows[0].facets).toEqual(facets);

        const second = await sql<{ facets: unknown }>`
          SELECT facets FROM "user".upsert_thread(
            ${userId}::uuid,
            ${JSON.stringify({ id: threadId, title: "Newsletter v2" })}::jsonb,
            ${JSON.stringify({ priority_id: priorityId })}::jsonb
          )`.execute(trx);
        captured = second.rows[0];

        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    }

    expect(captured?.facets).toEqual({ format: "reading", automation: "automated", reach: "list" });
  });
});
