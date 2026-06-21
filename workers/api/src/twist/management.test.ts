import { randomUUID } from "node:crypto";

import { Kysely, PostgresDialect, sql, type Kysely as KyselyType } from "kysely";
import pg from "pg";
import { describe, expect, it } from "vitest";

// Importing from ../db sets up the pg bigint type parser as a module side effect.
import { type DB } from "../db";

import { getAll } from "./management";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

/**
 * A Kysely instance that counts the queries it executes. Seeding and the call
 * under test run inside a single transaction that is always rolled back, so the
 * DB is left untouched. FK/identity triggers are disabled via
 * `session_replication_role = replica` during seeding (mirrors limits.test.ts).
 */
function makeCountingDb() {
  let count = 0;
  const pool = new pg.Pool({ connectionString: DATABASE_URL, max: 1 });
  const db = new Kysely<DB>({
    dialect: new PostgresDialect({ pool }),
    log(event) {
      if (event.level === "query") count++;
    },
  });
  return { db, getCount: () => count, reset: () => (count = 0) };
}

/** Insert a publisher (FK checks disabled by replica role) and return its id. */
async function seedPublisher(
  trx: KyselyType<DB>,
  fields: { name: string; email: string | null; url: string | null }
): Promise<string> {
  const res = await sql<{ id: string }>`
    INSERT INTO publisher (created_by, name, email, url)
    VALUES (${randomUUID()}::uuid, ${fields.name}, ${fields.email}, ${fields.url})
    RETURNING id`.execute(trx);
  return String(res.rows[0].id);
}

/** Insert a public twist owned by the given publisher. */
async function seedPublicTwist(
  trx: KyselyType<DB>,
  publisherId: string,
  name: string
): Promise<string> {
  const res = await sql<{ id: string }>`
    INSERT INTO twist
      (twist_package_id, environment, publisher_id, name, handle, version, is_source)
    VALUES (${randomUUID()}::uuid, 'public', ${publisherId}, ${name},
      ${name.toLowerCase()}, '1.0.0', false)
    RETURNING id`.execute(trx);
  return String(res.rows[0].id);
}

describe.skipIf(!DATABASE_URL)("getAll twist enrichment", () => {
  it("issues a bounded number of queries regardless of accessible twist count", async () => {
    const { db, getCount, reset } = makeCountingDb();
    const userId = randomUUID();
    let queriesForGetAll = 0;
    try {
      await db.transaction().execute(async (trx) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);

        // Many public twists from a single publisher. Each is visible to every
        // user via get_accessible_twists, so the N+1 enrichment would issue one
        // publisher query per twist.
        const pubId = await seedPublisher(trx, {
          name: `Pub ${userId}`,
          email: "pub@example.com",
          url: "https://pub.example.com",
        });
        for (let i = 0; i < 6; i++) {
          await seedPublicTwist(trx, pubId, `Twist ${userId} ${i}`);
        }

        reset();
        await getAll(trx, userId);
        queriesForGetAll = getCount();
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }

    // One RPC to fetch accessible twists + at most one batched publisher
    // lookup. Must NOT scale with the number of twists.
    expect(queriesForGetAll).toBeLessThanOrEqual(2);
  });

  it("maps publisher info onto public twists", async () => {
    const { db } = makeCountingDb();
    const userId = randomUUID();
    let result: any[] = [];
    let twistId = "";
    try {
      await db.transaction().execute(async (trx) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        const pubId = await seedPublisher(trx, {
          name: `Acme ${userId}`,
          email: "hello@acme.example",
          url: "https://acme.example",
        });
        twistId = await seedPublicTwist(trx, pubId, `AcmeTwist ${userId}`);
        result = (await getAll(trx, userId)) as any[];
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }

    const mine = result.find((t) => String(t.id) === twistId);
    expect(mine).toBeDefined();
    expect(mine.author_name).toBe(`Acme ${userId}`);
    expect(mine.author_email).toBe("hello@acme.example");
    expect(mine.author_url).toBe("https://acme.example");
  });

  it("labels personal twists as authored by You", async () => {
    const { db } = makeCountingDb();
    const userId = randomUUID();
    let result: any[] = [];
    let twistId = "";
    try {
      await db.transaction().execute(async (trx) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        const res = await sql<{ id: string }>`
          INSERT INTO twist
            (twist_package_id, environment, user_id, name, handle, version, is_source)
          VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
            'Mine', 'mine', '1.0.0', false)
          RETURNING id`.execute(trx);
        twistId = String(res.rows[0].id);
        result = (await getAll(trx, userId)) as any[];
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }

    const mine = result.find((t) => String(t.id) === twistId);
    expect(mine).toBeDefined();
    expect(mine.author_name).toBe("You");
    expect(mine.author_email).toBeNull();
    expect(mine.author_url).toBeNull();
  });
});
