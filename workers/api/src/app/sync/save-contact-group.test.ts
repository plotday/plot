import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";

const DATABASE_URL = process.env.DATABASE_URL;

class Rollback extends Error {}

/** Seed one user with a linked primary identity, run `fn`, then roll back. */
async function withUser<T>(
  fn: (trx: Kysely<DB>, userId: string) => Promise<T>,
): Promise<T> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const email = `wf-${userId}@example.test`;
  let captured: T;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(trx);
      await sql`SELECT public.upsert_user_contact(${userId}::uuid, ${email}, 'Owner', NULL)`.execute(trx);
      captured = await fn(trx, userId);
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
  return captured!;
}

describe.skipIf(!DATABASE_URL)("save_user_contact via rpcUser", () => {
  it("adds a contact by email and returns the canonical actor row", async () => {
    const result = await withUser(async (trx, userId) => {
      const contactId = randomUUID();
      const row = await rpcUser(trx, "save_user_contact", {
        user_id: userId,
        p_contact_id: contactId,
        p_email: `added-${contactId}@example.test`,
        p_name: "Added Person",
      });
      return { contactId, row };
    });
    expect((result.row as any).id).toBe(result.contactId);
    expect((result.row as any).name).toBe("Added Person");
  });
});

describe.skipIf(!DATABASE_URL)("save_group via rpcUser", () => {
  it("creates a group with the client id and returns it", async () => {
    const clientGroupId = randomUUID();
    const groupId = await withUser(async (trx, userId) => {
      return rpcUser(trx, "save_group", {
        user_id: userId,
        p_group: { id: clientGroupId, name: "Test Group", privacy: "open", member_contact_ids: [] },
      });
    });
    expect(groupId).toBe(clientGroupId);
  });

  it("rejects creating a group with a member that has no email", async () => {
    const clientGroupId = randomUUID();
    const emaillessContactId = randomUUID();
    await expect(
      withUser(async (trx, userId) => {
        // A contact with NO email (email column null).
        await sql`INSERT INTO contact (id, name) VALUES (${emaillessContactId}::uuid, 'No Email')`.execute(trx);
        return rpcUser(trx, "save_group", {
          user_id: userId,
          p_group: {
            id: clientGroupId,
            name: "Email Group",
            privacy: "open",
            member_contact_ids: [emaillessContactId],
          },
        });
      }),
    ).rejects.toThrow(/email/i);
  });

  it("creates a group when every member has an email", async () => {
    const clientGroupId = randomUUID();
    const memberId = randomUUID();
    const groupId = await withUser(async (trx, userId) => {
      await sql`INSERT INTO contact (id, name, email)
        VALUES (${memberId}::uuid, 'Has Email', ${`m-${memberId}@example.test`})`.execute(trx);
      return rpcUser(trx, "save_group", {
        user_id: userId,
        p_group: {
          id: clientGroupId,
          name: "Email Group",
          privacy: "open",
          member_contact_ids: [memberId],
        },
      });
    });
    expect(groupId).toBe(clientGroupId);
  });
});
