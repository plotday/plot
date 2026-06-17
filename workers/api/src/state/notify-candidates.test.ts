import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import {
  selectNotifyCandidates,
  selectUnsuppressedThreadIds,
  stampThreadsNotified,
} from "./notify-candidates";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

// Fixed timestamps so the millisecond-truncated comparisons are deterministic.
const T1 = "2026-01-01T00:00:00.000Z"; // thread's content version when notified
const T2 = "2026-01-02T00:00:00.000Z"; // later content version (a reply)

type SeedOpts = {
  /** Stamp thread_notify_state at this time (the user was already notified). */
  notifiedAt?: string | null;
  /** Re-file the thread into the second (uncleared) focus, as a move would. */
  moveToOtherFocus?: boolean;
  /** Bump thread_state.updated_at to this time, as a genuine reply would. */
  bumpStateTo?: string | null;
};

type Ids = { userId: string; threadId: string; focusA: string; focusB: string };

/**
 * Seed one user with two focuses, an unread+important thread filed in focus A,
 * and (optionally) a per-thread notify stamp / a move to focus B / a content
 * bump — then run `action` against the seeded data and roll back. Seeding and
 * the opts mutations run with triggers disabled so timestamps are exactly what
 * we set (the thread_state updated_at trigger would otherwise overwrite them);
 * `action` runs with triggers back on.
 */
async function runSeeded<T>(
  opts: SeedOpts,
  action: (trx: Kysely<DB>, ids: Ids) => Promise<T>
): Promise<T> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const ids: Ids = {
    userId: randomUUID(),
    threadId: randomUUID(),
    focusA: randomUUID(),
    focusB: randomUUID(),
  };
  const { userId, threadId, focusA, focusB } = ids;
  const contactId = randomUUID();
  const email = `notify-${userId}@example.test`;

  let captured: T | undefined;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(trx);
      await sql`INSERT INTO contact (id, user_id, "primary", email)
        VALUES (${contactId}::uuid, ${userId}::uuid, true, ${email})`.execute(trx);
      await sql`INSERT INTO user_contact (user_id, contact_id, linked, "primary")
        VALUES (${userId}::uuid, ${contactId}::uuid, true, true)`.execute(trx);

      // Two focuses (own role; priority_role_or_fyi CHECK requires role_id).
      // Each is its own first-level focus (nlevel 1), neither cleared.
      await sql`WITH r AS (
          INSERT INTO role (created_by, user_id, name)
          VALUES (${userId}::uuid, ${userId}::uuid, 'Test role') RETURNING id
        )
        INSERT INTO priority (id, created_by, user_id, title, path, role_id)
        SELECT v.id, ${userId}::uuid, ${userId}::uuid, v.title, v.path::ltree, r.id
        FROM r, (VALUES
          (${focusA}::uuid, 'Focus A', 'focusa'),
          (${focusB}::uuid, 'Focus B', 'focusb')
        ) AS v(id, title, path)`.execute(trx);

      await sql`INSERT INTO thread (id, created_by, title, contacts)
        VALUES (${threadId}::uuid, ${userId}::uuid, 'Test thread',
                ARRAY[${contactId}::uuid]::uuid[])`.execute(trx);
      await sql`INSERT INTO thread_priority (thread_id, user_id, priority_id)
        VALUES (${threadId}::uuid, ${userId}::uuid, ${focusA}::uuid)`.execute(trx);
      // Unread, important, content version = T1.
      await sql`INSERT INTO thread_state (user_id, thread_id, read_at, importance, updated_at)
        VALUES (${userId}::uuid, ${threadId}::uuid, NULL, 80, ${T1}::timestamptz)`.execute(trx);

      if (opts.notifiedAt) {
        await sql`INSERT INTO thread_notify_state (user_id, thread_id, notified_at)
          VALUES (${userId}::uuid, ${threadId}::uuid, ${opts.notifiedAt}::timestamptz)`.execute(trx);
      }
      if (opts.moveToOtherFocus) {
        // A move touches thread_priority only — NOT thread_state.
        await sql`UPDATE thread_priority SET priority_id = ${focusB}::uuid
          WHERE thread_id = ${threadId}::uuid AND user_id = ${userId}::uuid`.execute(trx);
      }
      if (opts.bumpStateTo) {
        await sql`UPDATE thread_state SET updated_at = ${opts.bumpStateTo}::timestamptz
          WHERE thread_id = ${threadId}::uuid AND user_id = ${userId}::uuid`.execute(trx);
      }

      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      captured = await action(trx, ids);
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }

  return captured as T;
}

/** Convenience wrapper: seed per opts, then return the notify-candidate IDs. */
async function seedAndQuery(opts: SeedOpts): Promise<{ threadId: string; candidateIds: string[] }> {
  let threadId = "";
  const candidateIds = await runSeeded(opts, async (trx, ids) => {
    threadId = ids.threadId;
    const rows = await selectNotifyCandidates(trx, ids.userId);
    return rows.map((r) => r.thread_id);
  });
  return { threadId, candidateIds };
}

describe.skipIf(!DATABASE_URL)("selectNotifyCandidates", () => {
  it("includes a fresh unread important thread that was never notified", async () => {
    const { threadId, candidateIds } = await seedAndQuery({});
    expect(candidateIds).toContain(threadId);
  });

  it("suppresses a thread already notified at its current content version", async () => {
    const { threadId, candidateIds } = await seedAndQuery({ notifiedAt: T1 });
    expect(candidateIds).not.toContain(threadId);
  });

  // The bug: moving an already-notified, still-unread thread to another
  // (uncleared) focus re-announced it. The per-thread mark must follow the
  // thread across the move, so it stays suppressed.
  it("stays suppressed after the thread is moved to another focus", async () => {
    const { threadId, candidateIds } = await seedAndQuery({
      notifiedAt: T1,
      moveToOtherFocus: true,
    });
    expect(candidateIds).not.toContain(threadId);
  });

  it("re-notifies after a genuine reply bumps the content version", async () => {
    const { threadId, candidateIds } = await seedAndQuery({
      notifiedAt: T1,
      bumpStateTo: T2,
    });
    expect(candidateIds).toContain(threadId);
  });

  // A reply AND a move together: the reply (newer content) wins, so it should
  // still re-notify even though it also moved focuses.
  it("re-notifies after a reply even if the thread also moved focuses", async () => {
    const { threadId, candidateIds } = await seedAndQuery({
      notifiedAt: T1,
      moveToOtherFocus: true,
      bumpStateTo: T2,
    });
    expect(candidateIds).toContain(threadId);
  });
});

// selectUnsuppressedThreadIds / stampThreadsNotified back the foreground
// /notification-summary fix (the client builds the batch; the server drops
// already-notified threads and records the ones it shows).
describe.skipIf(!DATABASE_URL)("selectUnsuppressedThreadIds", () => {
  it("returns a never-notified thread as eligible", async () => {
    const eligible = await runSeeded({}, (trx, ids) =>
      selectUnsuppressedThreadIds(trx, ids.userId, [ids.threadId])
    );
    expect([...eligible]).toHaveLength(1);
  });

  it("drops a thread already notified at its current version", async () => {
    const eligible = await runSeeded({ notifiedAt: T1 }, (trx, ids) =>
      selectUnsuppressedThreadIds(trx, ids.userId, [ids.threadId])
    );
    expect([...eligible]).toHaveLength(0);
  });

  // The foreground bug: a notified thread the user moved to another focus is
  // still handed to /notification-summary by the client — it must be dropped.
  it("drops an already-notified thread even after it moved focus", async () => {
    const { threadId, eligible } = await runSeeded(
      { notifiedAt: T1, moveToOtherFocus: true },
      async (trx, ids) => ({
        threadId: ids.threadId,
        eligible: await selectUnsuppressedThreadIds(trx, ids.userId, [ids.threadId]),
      })
    );
    expect(eligible.has(threadId)).toBe(false);
  });

  it("keeps a thread eligible after a genuine reply", async () => {
    const { threadId, eligible } = await runSeeded(
      { notifiedAt: T1, bumpStateTo: T2 },
      async (trx, ids) => ({
        threadId: ids.threadId,
        eligible: await selectUnsuppressedThreadIds(trx, ids.userId, [ids.threadId]),
      })
    );
    expect(eligible.has(threadId)).toBe(true);
  });

  it("ignores unknown / foreign thread ids", async () => {
    const foreign = randomUUID();
    const eligible = await runSeeded({}, (trx, ids) =>
      selectUnsuppressedThreadIds(trx, ids.userId, [foreign])
    );
    expect(eligible.has(foreign)).toBe(false);
  });
});

describe.skipIf(!DATABASE_URL)("stampThreadsNotified", () => {
  it("marks a thread so it is no longer eligible", async () => {
    const { threadId, before, after } = await runSeeded({}, async (trx, ids) => {
      const before = await selectUnsuppressedThreadIds(trx, ids.userId, [ids.threadId]);
      await stampThreadsNotified(trx, ids.userId, [ids.threadId]);
      const after = await selectUnsuppressedThreadIds(trx, ids.userId, [ids.threadId]);
      return { threadId: ids.threadId, before, after };
    });
    expect(before.has(threadId)).toBe(true);
    expect(after.has(threadId)).toBe(false);
  });

  it("re-opens eligibility once content advances past the stamp", async () => {
    // Stamp at the current version, then a reply bumps the version → eligible.
    const { threadId, after } = await runSeeded({ bumpStateTo: null }, async (trx, ids) => {
      await stampThreadsNotified(trx, ids.userId, [ids.threadId]);
      await sql`UPDATE thread_state SET updated_at = ${T2}::timestamptz
        WHERE thread_id = ${ids.threadId}::uuid AND user_id = ${ids.userId}::uuid`.execute(trx);
      return {
        threadId: ids.threadId,
        after: await selectUnsuppressedThreadIds(trx, ids.userId, [ids.threadId]),
      };
    });
    expect(after.has(threadId)).toBe(true);
  });
});
