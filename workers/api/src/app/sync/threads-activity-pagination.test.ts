/**
 * Tests for selectThreadIdsByActivity — the phase-1 candidate pre-filter that
 * lets GET /sync/threads (sortBy=activity_at) paginate the feed off the
 * (user_id, activity_at DESC) index instead of materializing the user.thread
 * view over the user's whole corpus to sort+limit.
 *
 * CONTRACT: phase-1 candidates are a SUPERSET of the visible feed (phase-1 only
 * knows thread_priority — revoked / per-user archive — not the thread-level
 * visibility the view enforces). Phase-2 re-fetches the full view for those ids,
 * dropping any that fail visibility. Paginating the two-phase query by the
 * activity_at cursor must therefore reach exactly the same set, in the same
 * order, as paginating the single-phase view query — even though an individual
 * page may come back short.
 */
import { beforeAll, describe, expect, it } from "vitest";

import { selectThreadIdsByActivity } from "./helpers";

const DATABASE_URL = process.env.DATABASE_URL;

const USER = "99999999-aaaa-0000-0000-000000000001";
const CONTACT = "99999999-aaaa-0000-0000-000000000002";
const OTHER_CONTACT = "99999999-aaaa-0000-0000-000000000009";
const PRIORITY = "99999999-aaaa-0000-0000-000000000003";
const T = (suffix: string) =>
  `99999999-aaaa-1111-0000-0000${suffix.padStart(8, "0")}`.toLowerCase();

describe.skipIf(!DATABASE_URL)(
  "selectThreadIdsByActivity: two-phase feed pagination ≡ single-phase (txn rollback)",
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

    // Seed: 5 visible threads (ascending activity_at), 1 invisible-but-filed
    // (contacts don't include the user; non-revoked tp), 1 revoked. Triggers off
    // so explicit activity_at sticks.
    const VISIBLE_DESC = [T("5"), T("4"), T("3"), T("2"), T("1")];
    async function seed(trx: any) {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      await sql`INSERT INTO "user" (id, email) VALUES (${USER}, 'act-test@invalid.test')`.execute(trx);
      await sql`INSERT INTO contact (id, email, user_id, "primary") VALUES (${CONTACT}, 'act-c@invalid.test', ${USER}, true)`.execute(trx);
      await sql`INSERT INTO contact (id, email) VALUES (${OTHER_CONTACT}, 'act-other@invalid.test')`.execute(trx);
      await sql`INSERT INTO user_contact (user_id, contact_id, linked, "primary") VALUES (${USER}, ${CONTACT}, true, true)`.execute(trx);
      await sql`WITH r AS (
          INSERT INTO role (created_by, user_id, name) VALUES (${USER}, ${USER}, 'Test role') RETURNING id
        )
        INSERT INTO priority (id, created_by, title, path, user_id, role_id)
        SELECT ${PRIORITY}, ${USER}, 'Root', 'acttestroot', ${USER}, r.id FROM r`.execute(trx);

      const mk = async (
        id: string,
        minutesAgo: number,
        opts: { contacts: string; revoked?: boolean } = { contacts: CONTACT },
      ) => {
        await sql`
          INSERT INTO thread (id, created_by, title, contacts)
          VALUES (${id}, ${USER}, ${"t" + id.slice(-2)}, ARRAY[${opts.contacts}]::uuid[])
        `.execute(trx);
        await sql`
          INSERT INTO thread_priority (thread_id, user_id, priority_id, activity_at, revoked_at)
          VALUES (${id}, ${USER}, ${PRIORITY}, now() - (${minutesAgo} || ' minutes')::interval,
                  ${opts.revoked ? sql`now()` : sql`NULL`})
        `.execute(trx);
      };

      // Visible, newest → oldest activity_at.
      await mk(T("5"), 1);
      await mk(T("4"), 2);
      await mk(T("3"), 3);
      await mk(T("2"), 4);
      await mk(T("1"), 5);
      // Invisible (user not in contacts) but filed & non-revoked, NEWEST of all
      // — exercises the superset/short-page path (phase-1 includes, phase-2 drops).
      await mk(T("a"), 0, { contacts: OTHER_CONTACT });
      // Revoked — must be excluded by phase-1 itself.
      await mk(T("b"), 0, { contacts: CONTACT, revoked: true });
    }

    const singlePhasePage = (trx: any, cursor: string | null, limit: number) => {
      let q = trx
        .selectFrom("user.thread")
        .select(["id", "activity_at"])
        .where("user_id", "=", USER)
        .where("archived_at", "is", null)
        .orderBy("activity_at", "desc")
        .orderBy("id", "desc")
        .limit(limit);
      if (cursor) q = q.where(sql`activity_at < ${cursor}::timestamptz`);
      return q.execute();
    };

    const twoPhasePage = async (trx: any, cursor: string | null, limit: number) => {
      const ids = await selectThreadIdsByActivity(trx, USER, {
        priorityId: null,
        rangeStart: null,
        rangeEnd: cursor,
        sortDir: "desc",
        archived: false,
        limit,
      });
      if (ids.length === 0) return [];
      return trx
        .selectFrom("user.thread")
        .select(["id", "activity_at"])
        .where("user_id", "=", USER)
        .where("archived_at", "is", null)
        .where(sql`id = ANY(${ids}::uuid[])`)
        .orderBy("activity_at", "desc")
        .orderBy("id", "desc")
        .limit(limit)
        .execute();
    };

    async function paginateAll(
      trx: any,
      page: (trx: any, cursor: string | null, limit: number) => Promise<any[]>,
      limit: number,
    ): Promise<string[]> {
      const out: string[] = [];
      let cursor: string | null = null;
      // Bound the loop defensively.
      for (let i = 0; i < 50; i++) {
        const rows = await page(trx, cursor, limit);
        if (rows.length === 0) break;
        for (const r of rows) out.push(r.id);
        cursor = rows[rows.length - 1].activity_at.toISOString();
      }
      return out;
    }

    it("a single two-phase page matches the single-phase page (all-visible top)", async () => {
      await inRollback(async (trx) => {
        await seed(trx);
        // Cursor just below the invisible thread so the top of both is visible.
        const single = await singlePhasePage(trx, null, 3);
        const two = await twoPhasePage(trx, null, 3);
        // Single-phase top-3 visible = [5,4,3]. Two-phase phase-1 top-3 by
        // activity_at = [i,5,4]; phase-2 drops i → [5,4] (short page).
        expect(single.map((r: any) => r.id)).toEqual([T("5"), T("4"), T("3")]);
        expect(two.map((r: any) => r.id)).toEqual([T("5"), T("4")]);
      });
    });

    it("paginating two-phase reaches exactly the visible set, in order", async () => {
      await inRollback(async (trx) => {
        await seed(trx);
        const single = await paginateAll(trx, singlePhasePage, 2);
        const two = await paginateAll(trx, twoPhasePage, 2);
        expect(single).toEqual(VISIBLE_DESC);
        expect(two).toEqual(VISIBLE_DESC); // excludes invisible + revoked
      });
    });

    it("phase-1 excludes revoked rows and respects the priority filter", async () => {
      await inRollback(async (trx) => {
        await seed(trx);
        const ids = await selectThreadIdsByActivity(trx, USER, {
          priorityId: PRIORITY,
          rangeStart: null,
          rangeEnd: null,
          sortDir: "desc",
          archived: false,
          limit: 100,
        });
        expect(ids).not.toContain(T("b")); // revoked excluded
        expect(ids).toContain(T("5"));
        // priority_id filter keeps the filed set
        expect(ids).toContain(T("a")); // filed in PRIORITY (visibility checked in phase-2)
      });
    });
  },
);
