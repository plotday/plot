/**
 * Tests for selectChangedThreadIds — the candidate pre-filter that lets the
 * GET /sync/threads phase-1 seq pull avoid scanning all of a user's threads.
 *
 * Phase-1 used to compute `GREATEST(thread.seq, last_note_seq, tp.seq, ts.seq)`
 * for EVERY one of the user's thread_priority rows (a full thread seq-scan +
 * per-row STABLE visibility functions), then filter on the computed seq — O(the
 * user's whole thread count) even when nothing changed. selectChangedThreadIds
 * gathers, via three cheap index range scans, the small set of thread ids that
 * COULD have advanced past the cursor:
 *
 *   tp.seq  >= since          (this user's filing changed)
 *   ts.seq  >= since          (this user's per-thread state changed)
 *   thread.seq >= since  ∩  this user has a thread_priority row   (content changed)
 *
 * The view-seq is GREATEST(thread.seq, last_note_seq, tp.seq, ts.seq). The
 * last_note_seq source is deliberately NOT a fourth branch: update_thread_on_
 * note_change always bumps thread.seq in the same txn it bumps last_note_seq
 * (the UNSCOPED branch UPDATEs thread → the BEFORE update_seq_and_updated_at
 * trigger fires), so last_note_seq <= thread.seq always and the thread.seq
 * branch subsumes it. invariant-last-note-seq below pins that.
 *
 * CONTRACT: the candidate set must be a SUPERSET of every thread whose view-seq
 * is >= since and visible to the user. Phase-1 then re-filters those candidates
 * through the unchanged user.thread view (same GREATEST, same pg_snapshot_xmin
 * horizon, same ORDER BY/LIMIT), so constraining phase-1 to `id = ANY(candidates)`
 * must produce byte-identical keys to the un-constrained phase-1. Over-inclusion
 * is harmless (the view drops it); UNDER-inclusion strands a client update — so
 * every seq source gets an independent scenario here.
 */

import { beforeAll, describe, expect, it } from "vitest";

import { seqSinceCursor, selectChangedThreadIds } from "./helpers";

const DATABASE_URL = process.env.DATABASE_URL;

const USER = "99999999-cccc-0000-0000-000000000001";
const CONTACT = "99999999-cccc-0000-0000-000000000002";
const PRIORITY = "99999999-cccc-0000-0000-000000000003";
// Postgres normalizes uuids to lowercase, so keep literal suffixes lowercase.
const T = (suffix: string) =>
  `99999999-cccc-1111-0000-0000${suffix.padStart(8, "0")}`.toLowerCase();

describe.skipIf(!DATABASE_URL)(
  "selectChangedThreadIds: candidate pre-filter ≡ unconstrained phase-1 (txn rollback)",
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
     * Seed a user + root priority and a set of threads where the max seq across
     * the four view-seq sources is carried by a chosen source per thread.
     * Triggers off (replica) so explicit seqs stick. Returns the cursor base.
     */
    async function seed(trx: any): Promise<bigint> {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      const baseRow = await sql`
        SELECT GREATEST(1, pg_current_xact_id()::text::bigint - 1000)::text AS base
      `.execute(trx);
      const base = BigInt(baseRow.rows[0].base);

      await sql`INSERT INTO "user" (id, email) VALUES (${USER}, 'cand-test@invalid.test')`.execute(trx);
      await sql`INSERT INTO contact (id, email, user_id, "primary") VALUES (${CONTACT}, 'cand-test-c@invalid.test', ${USER}, true)`.execute(trx);
      await sql`INSERT INTO user_contact (user_id, contact_id, linked, "primary") VALUES (${USER}, ${CONTACT}, true, true)`.execute(trx);
      await sql`WITH r AS (
          INSERT INTO role (created_by, user_id, name) VALUES (${USER}, ${USER}, 'Test role') RETURNING id
        )
        INSERT INTO priority (id, created_by, title, path, user_id, role_id)
        SELECT ${PRIORITY}, ${USER}, 'Test Root', 'candtestroot', ${USER}, r.id FROM r`.execute(trx);

      // Helper to insert a thread + its tp/ts with explicit seqs.
      const mk = async (
        id: string,
        opts: { threadSeq: bigint; lastNoteSeq?: bigint; tpSeq: bigint; tsSeq?: bigint },
      ) => {
        await sql`
          INSERT INTO thread (id, created_by, title, contacts, seq, last_note_seq)
          VALUES (${id}, ${USER}, ${"t" + id.slice(-2)}, ARRAY[${CONTACT}]::uuid[],
                  ${String(opts.threadSeq)}::xid8, ${String(opts.lastNoteSeq ?? 0n)}::xid8)
        `.execute(trx);
        await sql`
          INSERT INTO thread_priority (thread_id, user_id, priority_id, seq)
          VALUES (${id}, ${USER}, ${PRIORITY}, ${String(opts.tpSeq)}::xid8)
        `.execute(trx);
        if (opts.tsSeq !== undefined) {
          await sql`
            INSERT INTO thread_state (user_id, thread_id, seq, importance)
            VALUES (${USER}, ${id}, ${String(opts.tsSeq)}::xid8, 50)
          `.execute(trx);
        }
      };

      // A: content change — thread.seq is the max.
      await mk(T("A"), { threadSeq: base + 50n, tpSeq: base + 1n });
      // B: filing change — tp.seq is the max (thread.seq below cursor base).
      await mk(T("B"), { threadSeq: base - 5n, tpSeq: base + 60n });
      // C: per-user state change — ts.seq is the max (thread+tp below base).
      await mk(T("C"), { threadSeq: base - 5n, tpSeq: base - 5n, tsSeq: base + 70n });
      // D: note change — last_note_seq is the max, but thread.seq tracks it
      //    (invariant: update_thread_on_note_change bumps both in one txn).
      await mk(T("D"), { threadSeq: base + 80n, lastNoteSeq: base + 80n, tpSeq: base - 5n });
      // E: untouched — every source below the cursor base. Must be excluded.
      await mk(T("E"), { threadSeq: base - 5n, tpSeq: base - 5n });

      return base;
    }

    /** Unconstrained phase-1 (the current shape): scan the whole view. */
    const unconstrainedKeys = (trx: any, since: string) =>
      trx
        .selectFrom("user.thread")
        .select(["id", "seq"])
        .where("user_id", "=", USER)
        .where(seqSinceCursor(since, null, null))
        .orderBy("seq", "asc")
        .orderBy("id", "asc")
        .execute();

    /** Candidate-constrained phase-1 (the new shape). */
    const constrainedKeys = async (trx: any, since: string) => {
      const ids = await selectChangedThreadIds(trx, USER, since);
      if (ids.length === 0) return [];
      return trx
        .selectFrom("user.thread")
        .select(["id", "seq"])
        .where("user_id", "=", USER)
        .where(sql`id = ANY(${ids}::uuid[])`)
        .where(seqSinceCursor(since, null, null))
        .orderBy("seq", "asc")
        .orderBy("id", "asc")
        .execute();
    };

    it("candidate-constrained keys equal unconstrained keys (each seq source)", async () => {
      await inRollback(async (trx) => {
        const base = await seed(trx);
        const since = String(base);

        const unc = await unconstrainedKeys(trx, since);
        const con = await constrainedKeys(trx, since);

        const norm = (rows: any[]) =>
          rows.map((r) => `${r.seq}:${r.id}`);

        // The unconstrained set must include A (thread.seq), B (tp.seq),
        // C (ts.seq), D (last_note via thread.seq) — and exclude E.
        expect(unc.map((r: any) => r.id).sort()).toEqual(
          [T("A"), T("B"), T("C"), T("D")].sort(),
        );
        // Byte-identical: same rows, same order, same seqs.
        expect(norm(con)).toEqual(norm(unc));
      });
    });

    it("returns no candidates (and matches) when the cursor is caught up", async () => {
      await inRollback(async (trx) => {
        const base = await seed(trx);
        const since = String(base + 1000n); // past every seeded seq

        const ids = await selectChangedThreadIds(trx, USER, since);
        expect(ids).toEqual([]);

        const unc = await unconstrainedKeys(trx, since);
        const con = await constrainedKeys(trx, since);
        expect(unc).toEqual([]);
        expect(con).toEqual([]);
      });
    });

    it("each seq source is independently necessary (drop one → miss a row)", async () => {
      await inRollback(async (trx) => {
        const base = await seed(trx);
        const since = String(base);
        const ids = await selectChangedThreadIds(trx, USER, since);
        // C is only discoverable via the ts.seq branch (thread+tp below base);
        // B only via tp.seq; A/D only via thread.seq. All must be present.
        expect(ids).toContain(T("A"));
        expect(ids).toContain(T("B"));
        expect(ids).toContain(T("C"));
        expect(ids).toContain(T("D"));
      });
    });
  },
);
