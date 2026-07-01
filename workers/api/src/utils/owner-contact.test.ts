import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { resolveOwnerContact } from "./owner-contact";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

/**
 * Seed a user with the given contacts, run resolveOwnerContact, roll back.
 * Contacts are `[{ primary, ageMinutes }]`; ageMinutes sets created_at relative
 * to now (larger = older). Returns the resolved contact id and the seeded ids
 * in insertion order so the test can assert which one was picked.
 */
async function seedAndResolve(
  contacts: Array<{ primary: boolean; ageMinutes: number }>
): Promise<{ resolvedId: string | null; ids: string[] }> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const ids = contacts.map(() => randomUUID());
  let out: { resolvedId: string | null; ids: string[] } = { resolvedId: null, ids };
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      await sql`INSERT INTO "user" (id, email)
        VALUES (${userId}::uuid, ${`owner-${userId}@example.test`})`.execute(trx);
      for (let i = 0; i < contacts.length; i++) {
        const c = contacts[i];
        await sql`INSERT INTO contact (id, user_id, "primary", created_at)
          VALUES (${ids[i]}::uuid, ${userId}::uuid, ${c.primary},
                  now() - (${c.ageMinutes} * interval '1 minute'))`.execute(trx);
      }
      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      const resolved = await resolveOwnerContact(trx, userId);
      out = { resolvedId: resolved?.id ?? null, ids };
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
  return out;
}

describe.skipIf(!DATABASE_URL)("resolveOwnerContact", () => {
  it("returns the PRIMARY contact regardless of insertion/age order", async () => {
    // Primary is the newest row; a non-deterministic lookup could easily pick
    // the older non-primary one instead.
    const { resolvedId, ids } = await seedAndResolve([
      { primary: false, ageMinutes: 100 }, // oldest, non-primary
      { primary: true, ageMinutes: 1 }, // newest, primary
      { primary: false, ageMinutes: 50 },
    ]);
    expect(resolvedId).toBe(ids[1]);
  });

  it("falls back to the oldest contact when none is primary", async () => {
    const { resolvedId, ids } = await seedAndResolve([
      { primary: false, ageMinutes: 10 },
      { primary: false, ageMinutes: 100 }, // oldest
      { primary: false, ageMinutes: 50 },
    ]);
    expect(resolvedId).toBe(ids[1]);
  });

  it("returns null for a user with no contacts", async () => {
    const { resolvedId } = await seedAndResolve([]);
    expect(resolvedId).toBeNull();
  });
});
