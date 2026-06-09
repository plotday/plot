import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../../db";
import type { Bindings } from "../../env";
import { expandGroupsToContactIds } from "./threads";

const DATABASE_URL = process.env.DATABASE_URL;

class Rollback extends Error {}

/**
 * Seed a user (+linked primary contact), a group the user owns, two member
 * contacts with emails, then run `fn` with the trx and ids and roll back.
 */
async function withGroup<T>(
  fn: (
    trx: Kysely<DB>,
    ids: {
      userId: string;
      groupId: string;
      memberA: string;
      memberB: string;
    },
  ) => Promise<T>,
): Promise<T> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const selfContact = randomUUID();
  const groupId = randomUUID();
  const memberA = randomUUID();
  const memberB = randomUUID();
  const email = `wf-${userId}@example.test`;
  let captured: T;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(trx);
      await sql`INSERT INTO contact (id, user_id, "primary", email)
        VALUES (${selfContact}::uuid, ${userId}::uuid, true, ${email})`.execute(trx);
      await sql`INSERT INTO user_contact (user_id, contact_id, linked, "primary")
        VALUES (${userId}::uuid, ${selfContact}::uuid, true, true)`.execute(trx);
      await sql`INSERT INTO "group" (id, name, type, privacy, created_by)
        VALUES (${groupId}::uuid, 'Marketing', 'private', 'open', ${userId}::uuid)`.execute(trx);
      await sql`INSERT INTO group_admin (group_id, user_id)
        VALUES (${groupId}::uuid, ${userId}::uuid)`.execute(trx);
      await sql`INSERT INTO contact (id, name, email) VALUES
        (${memberA}::uuid, 'Alice', 'alice@example.test'),
        (${memberB}::uuid, 'Bob', 'bob@example.test')`.execute(trx);
      await sql`INSERT INTO group_member (group_id, contact_id) VALUES
        (${groupId}::uuid, ${memberA}::uuid),
        (${groupId}::uuid, ${memberB}::uuid)`.execute(trx);
      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
      captured = await fn(trx, { userId, groupId, memberA, memberB });
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
  return captured!;
}

describe.skipIf(!DATABASE_URL)("expandGroupsToContactIds", () => {
  it("expands a group to its member contact ids", async () => {
    const ids = await withGroup((trx, ids) =>
      expandGroupsToContactIds(trx, ids.userId, [], [ids.groupId]),
    );
    expect(ids.length).toBe(2);
  });

  it("dedups members already present as direct contacts", async () => {
    const result = await withGroup((trx, ids) =>
      expandGroupsToContactIds(trx, ids.userId, [ids.memberA], [ids.groupId]).then(
        (out) => ({ out, memberA: ids.memberA, memberB: ids.memberB }),
      ),
    );
    expect(result.out.sort()).toEqual([result.memberA, result.memberB].sort());
  });

  it("returns direct contacts unchanged when no groups are passed", async () => {
    const result = await withGroup((trx, ids) =>
      expandGroupsToContactIds(trx, ids.userId, [ids.memberA], []),
    );
    expect(result).toEqual([result[0]]);
    expect(result.length).toBe(1);
  });

  it("skips a group the user cannot address without throwing", async () => {
    const errors: unknown[] = [];
    const out = await withGroup(async (trx, ids) => {
      const otherUser = randomUUID();
      const foreignGroup = randomUUID();
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      await sql`INSERT INTO "user" (id, email) VALUES (${otherUser}::uuid, ${`o-${otherUser}@example.test`})`.execute(trx);
      await sql`INSERT INTO "group" (id, name, type, privacy, created_by)
        VALUES (${foreignGroup}::uuid, 'Private', 'private', 'private', ${otherUser}::uuid)`.execute(trx);
      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
      return expandGroupsToContactIds(
        trx,
        ids.userId,
        [ids.memberA],
        [foreignGroup],
        (e) => errors.push(e),
      );
    });
    expect(out).toEqual([out[0]]); // only the direct contact survives
    expect(errors).toHaveLength(0); // permission RAISE (P0001) is expected, not reported
  });
});
