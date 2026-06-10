/**
 * DB integration (txn rollback) for the user.merge_priority RPC wiring used
 * by POST /sync/priorities/merge.
 *
 * Function semantics (what moves, what's preserved, error cases) are pinned
 * by pgTAP in libs/db/tests/68-merge-priority-and-reclassify-scope.sql; this
 * test exercises the TypeScript side — rpcUser argument serialization and
 * the returned count — against a real database. Skipped when DATABASE_URL is
 * unset (CI without a DB).
 */

import { beforeAll, describe, expect, it } from "vitest";

const DATABASE_URL = process.env.DATABASE_URL;

const USER = "99999999-bbbb-0000-0000-000000000001";
const SOURCE = "99999999-bbbb-0000-0000-000000000002";
const TARGET = "99999999-bbbb-0000-0000-000000000003";
const THREAD = (i: number) =>
  `99999999-bbbb-1111-0000-${String(i).padStart(12, "0")}`;

describe.skipIf(!DATABASE_URL)(
  "DB integration: merge_priority via rpcUser (txn rollback)",
  () => {
    let db: any;
    let sql: any;

    beforeAll(async () => {
      const mod = await import("../../db");
      db = mod.createDb({ DATABASE_URL } as any);
      sql = mod.sql;
    });

    async function inRollback(fn: (trx: any) => Promise<void>) {
      try {
        await db.transaction().execute(async (trx: any) => {
          await fn(trx);
          throw Object.assign(new Error("__rollback__"), { isRollback: true });
        });
      } catch (e: any) {
        if (!e.isRollback) throw e;
      }
    }

    async function seed(trx: any) {
      await sql`INSERT INTO "user" (id, email) VALUES (${USER}, 'merge-rpc-test@invalid.test')`.execute(trx);
      const root = await sql`
        SELECT path FROM priority
        WHERE user_id = ${USER} AND nlevel(path) = 1
        ORDER BY created_at ASC LIMIT 1
      `.execute(trx);
      const rootPath = root.rows[0].path;
      await sql`
        INSERT INTO priority (id, created_by, title, path, user_id) VALUES
          (${SOURCE}, ${USER}, 'Merge source', ${rootPath + ".mergerpcsrc"}, ${USER}),
          (${TARGET}, ${USER}, 'Merge target', ${rootPath + ".mergerpctgt"}, ${USER})
      `.execute(trx);
      for (let i = 1; i <= 2; i++) {
        await sql`
          INSERT INTO thread (id, created_by, title)
          VALUES (${THREAD(i)}, ${USER}, ${"merge rpc t" + i})
        `.execute(trx);
        await sql`
          INSERT INTO thread_priority (thread_id, user_id, priority_id, user_moved, classify_at)
          VALUES (${THREAD(i)}, ${USER}, ${SOURCE}, FALSE, NULL)
          ON CONFLICT (thread_id, user_id) DO UPDATE
            SET priority_id = EXCLUDED.priority_id,
                user_moved = EXCLUDED.user_moved,
                classify_at = EXCLUDED.classify_at
        `.execute(trx);
      }
    }

    it("moves the source filings, archives the source, returns the count", async () => {
      const { rpcUser } = await import("../../rpc");
      await inRollback(async (trx) => {
        await seed(trx);
        const moved = await rpcUser(trx, "merge_priority", {
          user_id: USER,
          p_source_priority_id: SOURCE,
          p_target_priority_id: TARGET,
        });
        expect(moved).toBe(2);

        const filed = await trx
          .selectFrom("thread_priority")
          .select(["thread_id", "user_moved"])
          .where("user_id", "=", USER)
          .where("priority_id", "=", TARGET)
          .execute();
        expect(filed.map((r: any) => r.thread_id).sort()).toEqual([
          THREAD(1),
          THREAD(2),
        ]);
        expect(filed.every((r: any) => r.user_moved === false)).toBe(true);

        const source = await trx
          .selectFrom("priority")
          .select(["archived_at"])
          .where("id", "=", SOURCE)
          .executeTakeFirst();
        expect(source?.archived_at).not.toBeNull();
      });
    });

    it("rejects merging a focus into itself with a P0001 the endpoint maps to 422", async () => {
      const { rpcUser } = await import("../../rpc");
      await inRollback(async (trx) => {
        await seed(trx);
        await expect(
          rpcUser(trx, "merge_priority", {
            user_id: USER,
            p_source_priority_id: SOURCE,
            p_target_priority_id: SOURCE,
          }),
        ).rejects.toMatchObject({ code: "P0001" });
      });
    });
  },
);
