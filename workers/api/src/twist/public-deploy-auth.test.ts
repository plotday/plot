import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { checkPublicDeployAllowed } from "./public-deploy-auth";

const DATABASE_URL = process.env.DATABASE_URL;
const describeDb = DATABASE_URL ? describe : describe.skip;

class Rollback extends Error {}

/** Insert a publisher with the given flag, run the check, roll back. */
async function withPublisher<T>(
  canPublishPublic: boolean,
  run: (trx: Kysely<DB>, publisherId: number) => Promise<T>,
): Promise<T> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  let result!: T;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      const row = await trx
        .insertInto("publisher")
        .values({
          // FK triggers are disabled, so a bare uuid for created_by is fine.
          created_by: randomUUID(),
          name: `Test Publisher ${randomUUID()}`,
          can_publish_public: canPublishPublic,
        })
        .returning(["id"])
        .executeTakeFirstOrThrow();
      result = await run(trx, Number(row.id));
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
  return result;
}

describeDb("checkPublicDeployAllowed", () => {
  it("allows public deploy when the publisher is granted", async () => {
    const res = await withPublisher(true, (trx, id) =>
      checkPublicDeployAllowed(trx, "public", id),
    );
    expect(res).toEqual({ ok: true });
  });

  it("denies public deploy with a clear, publisher-named message when not granted", async () => {
    const res = await withPublisher(false, (trx, id) =>
      checkPublicDeployAllowed(trx, "public", id),
    );
    expect(res.ok).toBe(false);
    if (res.ok) throw new Error("expected denial");
    expect(res.message).toContain("not approved to publish to the public environment");
    expect(res.message).toContain("Test Publisher");
  });

  it("allows non-public environments without checking the publisher", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    try {
      expect(await checkPublicDeployAllowed(db, "review", null)).toEqual({ ok: true });
      expect(await checkPublicDeployAllowed(db, "personal", null)).toEqual({ ok: true });
    } finally {
      await db.destroy();
    }
  });

  it("denies a public deploy with no resolved publisher", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    try {
      const res = await checkPublicDeployAllowed(db, "public", null);
      expect(res.ok).toBe(false);
    } finally {
      await db.destroy();
    }
  });
});
