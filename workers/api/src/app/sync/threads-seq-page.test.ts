/**
 * Tests for assembleSeqPage — the page-assembly step of the two-phase
 * GET /sync/threads seq-cursor fetch.
 *
 * The two-phase fetch exists because the user.thread SELECT list is expensive
 * (agenda_at / activity_at each run correlated subqueries per row) and is
 * evaluated for every row passing the cursor filter, before the sort+limit.
 * Phase 1 fetches only (id, seq) keys; phase 2 projects full rows for at most
 * `limit` ids. assembleSeqPage merges phase-1 keys, phase-2 rows, and the
 * redacted stubs into the final page.
 *
 * Pagination-correctness invariants pinned here:
 *   - Phase-1 keys are authoritative for ordering and next_page derivation: a
 *     concurrent commit between the two statements may bump a row's seq, and
 *     using the newer seq could advance the cursor past unreturned rows.
 *   - A row that vanished between phases (access revoked mid-pull) keeps its
 *     KEY in the page (so `more` and next_page stay correct) but contributes
 *     no row.
 *   - seq ordering is numeric (xid8 decimal strings), not lexicographic:
 *     "999" < "1000".
 */

import { beforeAll, describe, expect, it } from "vitest";

import { assembleSeqPage, seqSinceCursor } from "./helpers";

type Row = { id: string; seq: string; title?: string };

const row = (id: string, seq: string, title?: string): Row => ({ id, seq, title });
const key = (id: string, seq: string) => ({ id, seq });

const byId = (rows: Row[]) => new Map(rows.map((r) => [r.id, r]));

describe("assembleSeqPage", () => {
  it("returns rows in phase-1 key order with matching pageKeys", () => {
    const keys = [key("a", "5"), key("b", "7"), key("c", "9")];
    const rows = [row("c", "9"), row("a", "5"), row("b", "7")];
    const page = assembleSeqPage(keys, byId(rows), [], 200);
    expect(page.rows.map((r) => r.id)).toEqual(["a", "b", "c"]);
    expect(page.pageKeys).toEqual(keys);
  });

  it("orders seq numerically, not lexicographically", () => {
    const keys = [key("a", "999"), key("b", "1000")];
    const rows = [row("a", "999"), row("b", "1000")];
    const page = assembleSeqPage(keys, byId(rows), [], 200);
    expect(page.pageKeys.map((k) => k.seq)).toEqual(["999", "1000"]);
  });

  it("breaks seq ties by id ascending", () => {
    const keys = [key("b", "5"), key("a", "5")];
    const rows = [row("a", "5"), row("b", "5")];
    const page = assembleSeqPage(keys, byId(rows), [], 200);
    expect(page.pageKeys.map((k) => k.id)).toEqual(["a", "b"]);
  });

  it("interleaves redacted stubs by (seq, id)", () => {
    const keys = [key("a", "5"), key("c", "9")];
    const rows = [row("a", "5"), row("c", "9")];
    const redacted = [row("b", "7", "stub")];
    const page = assembleSeqPage(keys, byId(rows), redacted, 200);
    expect(page.rows.map((r) => r.id)).toEqual(["a", "b", "c"]);
    expect(page.pageKeys.map((k) => k.id)).toEqual(["a", "b", "c"]);
  });

  it("keeps the key but drops the row when a visible row vanished between phases", () => {
    const keys = [key("a", "5"), key("gone", "7"), key("c", "9")];
    const rows = [row("a", "5"), row("c", "9")]; // "gone" revoked mid-pull
    const page = assembleSeqPage(keys, byId(rows), [], 200);
    expect(page.rows.map((r) => r.id)).toEqual(["a", "c"]);
    // The vanished row still occupies its page slot so next_page / `more`
    // (derived from pageKeys) cannot skip past rows the client never saw.
    expect(page.pageKeys.map((k) => k.id)).toEqual(["a", "gone", "c"]);
  });

  it("uses phase-1 seq for pagination even if phase 2 saw a newer seq", () => {
    const keys = [key("a", "5")];
    const rows = [row("a", "12345")]; // bumped by a concurrent commit
    const page = assembleSeqPage(keys, byId(rows), [], 200);
    expect(page.pageKeys).toEqual([key("a", "5")]);
    expect(page.rows[0]?.seq).toBe("12345"); // row content stays fresh
  });

  it("slices the merged set to the limit", () => {
    const keys = [key("a", "1"), key("b", "2"), key("c", "3")];
    const rows = [row("a", "1"), row("b", "2"), row("c", "3")];
    const redacted = [row("r", "0", "stub")];
    const page = assembleSeqPage(keys, byId(rows), redacted, 2);
    expect(page.pageKeys.map((k) => k.id)).toEqual(["r", "a"]);
    expect(page.rows.map((r) => r.id)).toEqual(["r", "a"]);
  });

  it("handles empty inputs", () => {
    const page = assembleSeqPage([], new Map(), [], 200);
    expect(page.rows).toEqual([]);
    expect(page.pageKeys).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// DB integration (txn rollback): two-phase fetch ≡ single-phase fetch
// ---------------------------------------------------------------------------

const DATABASE_URL = process.env.DATABASE_URL;

const USER = "99999999-aaaa-0000-0000-000000000001";
const CONTACT = "99999999-aaaa-0000-0000-000000000002";
const PRIORITY = "99999999-aaaa-0000-0000-000000000003";
const THREAD = (i: number) =>
  `99999999-aaaa-1111-0000-${String(i).padStart(12, "0")}`;

describe.skipIf(!DATABASE_URL)(
  "DB integration: two-phase seq fetch matches single-phase (txn rollback)",
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

    /**
     * Seed a user with `count` visible threads (one revoked → redacted stub)
     * whose seq values sit just below the current xid, so the seq-cursor
     * horizon filter (`seq < pg_snapshot_xmin(...)`) admits them. Triggers
     * are skipped (replica role) so the explicit seq values stick.
     * Returns the band base (cursor lower bound) as a decimal string.
     */
    async function seed(trx: any, count: number): Promise<string> {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      const baseRow = await sql`
        SELECT GREATEST(1, pg_current_xact_id()::text::bigint - 1000)::text AS base
      `.execute(trx);
      const base = BigInt(baseRow.rows[0].base);

      await sql`INSERT INTO "user" (id, email) VALUES (${USER}, 'two-phase-test@invalid.test')`.execute(trx);
      await sql`INSERT INTO contact (id, email, user_id, "primary") VALUES (${CONTACT}, 'two-phase-test-c@invalid.test', ${USER}, true)`.execute(trx);
      await sql`INSERT INTO user_contact (user_id, contact_id, linked, "primary") VALUES (${USER}, ${CONTACT}, true, true)`.execute(trx);
      // role_id is required (priority_role_or_fyi CHECK). Triggers are off in
      // replica mode, so create a role inline and file the root under it.
      await sql`WITH r AS (
          INSERT INTO role (created_by, user_id, name) VALUES (${USER}, ${USER}, 'Test role') RETURNING id
        )
        INSERT INTO priority (id, created_by, title, path, user_id, role_id)
        SELECT ${PRIORITY}, ${USER}, 'Test Root', 'twophasetestroot', ${USER}, r.id FROM r`.execute(trx);

      for (let i = 1; i <= count; i++) {
        const seq = String(base + BigInt(i));
        await sql`
          INSERT INTO thread (id, created_by, title, contacts, seq, last_note_seq)
          VALUES (${THREAD(i)}, ${USER}, ${"t" + i}, ARRAY[${CONTACT}]::uuid[], ${seq}::xid8, '0'::xid8)
        `.execute(trx);
        await sql`
          INSERT INTO thread_priority (thread_id, user_id, priority_id, seq, revoked_at)
          VALUES (${THREAD(i)}, ${USER}, ${PRIORITY}, ${seq}::xid8,
                  ${i === count ? new Date().toISOString() : null}::timestamptz)
        `.execute(trx);
      }
      return base.toString();
    }

    it("returns the same page as the single-phase query, including redacted stubs", async () => {
      await inRollback(async (trx) => {
        const since = await seed(trx, 6); // 5 visible + 1 revoked
        const limit = 4;

        // Single-phase (pre-change shape): full projection + merge.
        const singleVisible = await trx
          .selectFrom("user.thread")
          .selectAll()
          .where("user_id", "=", USER)
          .where(seqSinceCursor(since, null, null))
          .orderBy("seq", "asc")
          .orderBy("id", "asc")
          .limit(limit)
          .execute();
        const redacted = await trx
          .selectFrom("user.thread_redacted")
          .selectAll()
          .where("user_id", "=", USER)
          .where(seqSinceCursor(since, null, null))
          .orderBy("seq", "asc")
          .orderBy("id", "asc")
          .limit(limit)
          .execute();
        const merged = [...singleVisible, ...redacted]
          .sort((a: any, b: any) => {
            const as = BigInt(a.seq ?? "0");
            const bs = BigInt(b.seq ?? "0");
            if (as !== bs) return as < bs ? -1 : 1;
            return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
          })
          .slice(0, limit);

        // Two-phase (handler shape): keys, then rows by id.
        const keys = await trx
          .selectFrom("user.thread")
          .select(["id", "seq"])
          .where("user_id", "=", USER)
          .where(seqSinceCursor(since, null, null))
          .orderBy("seq", "asc")
          .orderBy("id", "asc")
          .limit(limit)
          .execute();
        const full =
          keys.length === 0
            ? []
            : await trx
                .selectFrom("user.thread")
                .selectAll()
                .where("user_id", "=", USER)
                .where("id", "in", keys.map((k: any) => k.id))
                .execute();
        const page = assembleSeqPage(
          keys,
          new Map<string, any>(full.map((r: any) => [r.id as string, r])),
          redacted,
          limit,
        );

        expect(page.rows.map((r: any) => r.id)).toEqual(
          merged.map((r: any) => r.id),
        );
        expect(page.pageKeys.map((k) => `${k.seq}:${k.id}`)).toEqual(
          merged.map((r: any) => `${r.seq}:${r.id}`),
        );
        expect(page.rows).toEqual(merged);

        // Sanity: the page is non-trivial and the revoked thread surfaces as
        // a redacted stub when the cursor window covers it.
        expect(page.rows.length).toBe(limit);
      });
    });

    it("phase-1 keys carry the view seq (GREATEST over thread/tp/state)", async () => {
      await inRollback(async (trx) => {
        const since = await seed(trx, 3);
        const keys = await trx
          .selectFrom("user.thread")
          .select(["id", "seq"])
          .where("user_id", "=", USER)
          .where(seqSinceCursor(since, null, null))
          .orderBy("seq", "asc")
          .orderBy("id", "asc")
          .execute();
        // 2 visible (third is revoked → excluded from user.thread).
        expect(keys.map((k: any) => k.id)).toEqual([THREAD(1), THREAD(2)]);
        expect(keys.map((k: any) => BigInt(k.seq))).toEqual([
          BigInt(since) + 1n,
          BigInt(since) + 2n,
        ]);
      });
    });
  },
);
