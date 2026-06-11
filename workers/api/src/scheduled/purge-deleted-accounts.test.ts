import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import {
  findUsersToPurge,
  purgeUserFiles,
  type FileBucket,
} from "./purge-deleted-accounts";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

// Run the DB-backed test only when a database is configured via DATABASE_URL.
// CI's unit step (`pnpm test`) has no DB; the integration step and local runs do.
describe.skipIf(!DATABASE_URL)("findUsersToPurge (DB)", () => {
  it("returns only users whose deletion request is older than 14 days", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const expired = randomUUID();
    const recent = randomUUID();
    const none = randomUUID();

    let ids: string[] = [];
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await sql`INSERT INTO "user" (id, email, deletion_requested_at)
          VALUES (${expired}::uuid, ${`purge-${expired}@example.test`}, now() - interval '15 days')`.execute(
          trx
        );
        await sql`INSERT INTO "user" (id, email, deletion_requested_at)
          VALUES (${recent}::uuid, ${`purge-${recent}@example.test`}, now() - interval '2 days')`.execute(
          trx
        );
        await sql`INSERT INTO "user" (id, email)
          VALUES (${none}::uuid, ${`purge-${none}@example.test`})`.execute(trx);

        ids = (await findUsersToPurge(trx)).map((u) => u.id);
        throw new Rollback();
      });
    } catch (error) {
      if (!(error instanceof Rollback)) throw error;
    } finally {
      await db.destroy();
    }

    expect(ids).toContain(expired);
    expect(ids).not.toContain(recent);
    expect(ids).not.toContain(none);
  });
});

describe("purgeUserFiles", () => {
  function fakeBucket(
    pages: Array<Array<{ key: string; uploadedBy?: string }>>
  ) {
    const deleted: string[] = [];
    let call = 0;
    const bucket: FileBucket = {
      async list() {
        const objects = (pages[call] ?? []).map((o) => ({
          key: o.key,
          customMetadata: o.uploadedBy
            ? { uploadedBy: o.uploadedBy }
            : undefined,
        }));
        call++;
        const truncated = call < pages.length;
        return truncated
          ? { objects, truncated: true as const, cursor: String(call) }
          : { objects, truncated: false as const };
      },
      async delete(keys: string | string[]) {
        deleted.push(...(Array.isArray(keys) ? keys : [keys]));
      },
    };
    return { bucket, deleted };
  }

  it("deletes only the user's files, across pages", async () => {
    const { bucket, deleted } = fakeBucket([
      [
        { key: "files/a/one.png", uploadedBy: "user-1" },
        { key: "files/b/two.png", uploadedBy: "user-2" },
      ],
      [
        { key: "files/c/three.png", uploadedBy: "user-1" },
        { key: "files/d/orphan.png" },
      ],
    ]);

    const count = await purgeUserFiles(bucket, "user-1");

    expect(count).toBe(2);
    expect(deleted.sort()).toEqual(["files/a/one.png", "files/c/three.png"]);
  });

  it("deletes nothing when the user has no files", async () => {
    const { bucket, deleted } = fakeBucket([
      [{ key: "files/b/two.png", uploadedBy: "user-2" }],
    ]);

    const count = await purgeUserFiles(bucket, "user-1");

    expect(count).toBe(0);
    expect(deleted).toEqual([]);
  });
});
