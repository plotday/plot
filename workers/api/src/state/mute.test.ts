import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";

import { applyMuteForNewThread } from "./mute";

const DATABASE_URL = process.env.DATABASE_URL;

class Rollback extends Error {}

type Ctx = {
  userId: string;
  ownerContactId: string;
  priorityId: string;
  senderId: string;
  otherSenderId: string;
};

// Real-DB fixture: a user with a self-referencing mute seed ("Skip active for
// threads like this") on a "New sign-in" thread sent by `senderId` over the
// `IMPORTANT` channel. The seed has a link carrying channel_id + author_id, as
// find_mute_candidates requires. Rolls back so the local DB is untouched.
async function withMuteSeed<T>(
  fn: (trx: Kysely<DB>, ctx: Ctx) => Promise<T>,
): Promise<T> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const email = `mute-${userId}@example.test`;
  let captured: T;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(trx);
      await sql`SELECT public.upsert_user_contact(${userId}::uuid, ${email}, 'Owner', NULL)`.execute(trx);
      const oc = await sql<{ id: string }>`
        SELECT unnest("user".user_contact_ids(${userId}::uuid)) AS id LIMIT 1
      `.execute(trx);
      const ownerContactId = oc.rows[0].id;
      const root = await sql<{ id: string }>`
        SELECT id FROM priority WHERE user_id = ${userId}::uuid ORDER BY path LIMIT 1
      `.execute(trx);
      const priorityId = root.rows[0].id;

      const senderId = randomUUID();
      const otherSenderId = randomUUID();
      await sql`INSERT INTO contact (id, email, name) VALUES (${senderId}::uuid, ${`s1-${senderId}@plot.day`}, 'Plot')`.execute(trx);
      await sql`INSERT INTO contact (id, email, name) VALUES (${otherSenderId}::uuid, ${`s2-${otherSenderId}@plot.day`}, 'Plot')`.execute(trx);

      // Seed thread + its link + self-referencing mute rule.
      const seedId = randomUUID();
      await sql`INSERT INTO thread (id, created_by, title, contacts)
                VALUES (${seedId}::uuid, ${userId}::uuid, 'New sign-in to your Plot account', ARRAY[${ownerContactId}::uuid])`.execute(trx);
      await sql`INSERT INTO thread_priority (thread_id, user_id, priority_id, mute_by_thread_id)
                VALUES (${seedId}::uuid, ${userId}::uuid, ${priorityId}::uuid, ${seedId}::uuid)`.execute(trx);
      await sql`INSERT INTO link (thread_id, channel_id, author_id, title)
                VALUES (${seedId}::uuid, 'IMPORTANT', ${senderId}::uuid, 'New sign-in to your Plot account')`.execute(trx);

      captured = await fn(trx, {
        userId,
        ownerContactId,
        priorityId,
        senderId,
        otherSenderId,
      });
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
  return captured!;
}

// Insert a freshly-arrived connector thread (thread + link), as createLink does
// for a Gmail email, and return its id. No thread_state — it has not been read.
async function arriveThread(
  trx: Kysely<DB>,
  ctx: Ctx,
  authorId: string,
): Promise<string> {
  const id = randomUUID();
  await sql`INSERT INTO thread (id, created_by, title, contacts)
            VALUES (${id}::uuid, ${ctx.userId}::uuid, 'New sign-in to your Plot account', ARRAY[${ctx.ownerContactId}::uuid])`.execute(trx);
  await sql`INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (${id}::uuid, ${ctx.userId}::uuid, ${ctx.priorityId}::uuid)`.execute(trx);
  await sql`INSERT INTO link (thread_id, channel_id, author_id, title)
            VALUES (${id}::uuid, 'IMPORTANT', ${authorId}::uuid, 'New sign-in to your Plot account')`.execute(trx);
  return id;
}

describe.skipIf(!DATABASE_URL)("applyMuteForNewThread", () => {
  it("mutes a newly arrived connector thread that matches a seed", async () => {
    await withMuteSeed(async (trx, ctx) => {
      const newThreadId = await arriveThread(trx, ctx, ctx.senderId);

      const matchedSeed = await applyMuteForNewThread(trx, ctx.userId, newThreadId);
      expect(matchedSeed).not.toBeNull();

      const tp = await sql<{ mute_by_thread_id: string | null }>`
        SELECT mute_by_thread_id::text FROM thread_priority
        WHERE thread_id = ${newThreadId}::uuid AND user_id = ${ctx.userId}::uuid
      `.execute(trx);
      expect(tp.rows[0].mute_by_thread_id).toBe(matchedSeed);

      const ts = await sql<{ active: boolean; read_at: string | null }>`
        SELECT active, read_at::text FROM thread_state
        WHERE thread_id = ${newThreadId}::uuid AND user_id = ${ctx.userId}::uuid
      `.execute(trx);
      expect(ts.rows[0]?.active).toBe(false);
      expect(ts.rows[0]?.read_at).not.toBeNull();
    });
  });

  it("keeps a muted thread read when a later note re-marks it unread", async () => {
    // Regression: apply_mute_for_new_thread marks the thread read + inactive,
    // but the async note-analysis / connector-fallback path later calls
    // upsert_thread_state to mark it unread (p_read_at NULL). That writer
    // passes its own now() as p_note_created_at — newer than the mute's
    // read_at — so the read-vs-note race guard doesn't protect the mute, and
    // read_at was clobbered to NULL. The thread then reappeared unread in
    // Active despite being muted. upsert_thread_state must preserve the read
    // marker on a muted thread.
    await withMuteSeed(async (trx, ctx) => {
      const newThreadId = await arriveThread(trx, ctx, ctx.senderId);

      const matchedSeed = await applyMuteForNewThread(trx, ctx.userId, newThreadId);
      expect(matchedSeed).not.toBeNull();

      // A later note lands and the ingest path tries to mark the thread
      // unread. It passes its own ingest wall-clock (strictly AFTER the mute's
      // read_at) as p_note_created_at, so the read-vs-note race guard does not
      // fire. In prod these are separate transactions; within this single test
      // txn now() is constant, so add an interval to model the later clock.
      await sql`
        SELECT "user".upsert_thread_state(
          user_id => ${ctx.userId}::uuid,
          p_thread_id => ${newThreadId}::uuid,
          p_set_read_at => true,
          p_note_created_at => now() + interval '5 seconds',
          p_write_source => ${matchedSeed}::uuid
        )
      `.execute(trx);

      const ts = await sql<{ active: boolean; read_at: string | null }>`
        SELECT active, read_at::text FROM thread_state
        WHERE thread_id = ${newThreadId}::uuid AND user_id = ${ctx.userId}::uuid
      `.execute(trx);
      // Muted thread must stay read (and inactive) — not resurface in Active.
      expect(ts.rows[0]?.read_at).not.toBeNull();
      expect(ts.rows[0]?.active).toBe(false);
    });
  });

  it("does NOT mute when the sender (link author) differs from the seed", async () => {
    // This is the production scenario: the sign-in sender's contact changed
    // (old fallback author deleted, new mail keyed on the real sender), so the
    // rule's author condition no longer matches.
    await withMuteSeed(async (trx, ctx) => {
      const newThreadId = await arriveThread(trx, ctx, ctx.otherSenderId);

      const matchedSeed = await applyMuteForNewThread(trx, ctx.userId, newThreadId);
      expect(matchedSeed).toBeNull();

      const tp = await sql<{ mute_by_thread_id: string | null }>`
        SELECT mute_by_thread_id::text FROM thread_priority
        WHERE thread_id = ${newThreadId}::uuid AND user_id = ${ctx.userId}::uuid
      `.execute(trx);
      expect(tp.rows[0].mute_by_thread_id).toBeNull();
    });
  });
});
