/**
 * Regression test for the cross-device unread bug: "read a thread on web, reply,
 * open another device → still unread."
 *
 * `user.clear_thread_state` has a freshness guard that only sets `read_at` when
 * the pushed read marker is at least as new as the latest content on the thread.
 * The read marker is captured when the thread is opened (= newest note visible
 * then). When the user then REPLIES, their own note advances the thread's
 * `last_note_source_created_at` past that captured marker, so the deferred
 * `/sync/thread-state` drain pushes a now-stale `read_at` and the guard silently
 * rejects it — leaving the thread unread server-side and on every other device.
 *
 * A note the user authored is content they have obviously seen, so it must not
 * block their own read marker. This test pins that: when the only content newer
 * than the read marker is a note the user wrote, the read still lands.
 *
 * DB integration (txn rollback). Skipped when DATABASE_URL is unset.
 */

import { sql } from "kysely";
import { beforeAll, describe, expect, it } from "vitest";

const DATABASE_URL = process.env.DATABASE_URL;

describe.skipIf(!DATABASE_URL)(
  "clear_thread_state ignores the user's own notes in the freshness guard",
  () => {
    let db: any;
    let userId = "";
    let threadId = "";

    beforeAll(async () => {
      const { createDb } = await import("../../db");
      db = createDb({ DATABASE_URL } as any);

      // Any user+thread with a settled, unrevoked filing so clear_thread_state
      // takes the synchronous path (no "Thread not found").
      const row = await db
        .selectFrom("thread_priority as tp")
        .innerJoin("thread as t", "t.id", "tp.thread_id")
        .select(["tp.user_id as user_id", "tp.thread_id as thread_id"])
        .where("tp.priority_id", "is not", null)
        .where("tp.revoked_at", "is", null)
        .where("t.archived_at", "is", null)
        .executeTakeFirst();
      userId = row?.user_id ?? "";
      threadId = row?.thread_id ?? "";
      expect(userId).not.toBe("");
      expect(threadId).not.toBe("");
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

    it("marks read when the only newer content is a note the user authored", async () => {
      const { rpcUser } = await import("../../rpc");

      await inRollback(async (trx) => {
        // Existing unread thread_state row, so clear_thread_state exercises the
        // ON CONFLICT (guarded) branch rather than the unconditional INSERT.
        await sql`
          INSERT INTO public.thread_state (user_id, thread_id, read_at)
          VALUES (${userId}::uuid, ${threadId}::uuid, NULL)
          ON CONFLICT (user_id, thread_id) DO UPDATE SET read_at = NULL
        `.execute(trx);

        // The user's own reply, dated far in the future so it is unambiguously
        // the newest content on the thread (bumps thread.last_note_source_created_at
        // via the note trigger). created_by = the user => "the user's own note".
        await sql`
          INSERT INTO public.note
            (thread_id, created_by, author_id, source_created_at, created_at, content, draft)
          VALUES
            (${threadId}::uuid, ${userId}::uuid, ${userId}::uuid,
             '2999-01-01T00:00:00.000Z'::timestamptz, now(), 'my own reply', false)
        `.execute(trx);

        // Read marker captured at open time: now(), older than the user's own
        // future reply but newer than every other (real, past) note + created_at.
        const readAt = new Date().toISOString();
        await rpcUser(trx, "clear_thread_state", {
          user_id: userId,
          p_thread_id: threadId,
          p_read_at: readAt,
        } as any);

        const stored = await trx
          .selectFrom("thread_state")
          .select(["read_at"])
          .where("user_id", "=", userId)
          .where("thread_id", "=", threadId)
          .executeTakeFirst();

        expect(stored?.read_at).not.toBeNull();
        expect(stored?.read_at).toBeDefined();
      });
    });

    it("still rejects a stale read when another actor's note is newer", async () => {
      const { rpcUser } = await import("../../rpc");

      await inRollback(async (trx) => {
        await sql`
          INSERT INTO public.thread_state (user_id, thread_id, read_at)
          VALUES (${userId}::uuid, ${threadId}::uuid, NULL)
          ON CONFLICT (user_id, thread_id) DO UPDATE SET read_at = NULL
        `.execute(trx);

        // A note from SOMEONE ELSE (created_by is a different uuid), in the
        // future, so it is genuinely unseen content newer than the read marker.
        await sql`
          INSERT INTO public.note
            (thread_id, created_by, author_id, source_created_at, created_at, content, draft)
          VALUES
            (${threadId}::uuid, gen_random_uuid(), gen_random_uuid(),
             '2999-01-01T00:00:00.000Z'::timestamptz, now(), 'their reply', false)
        `.execute(trx);

        const readAt = new Date().toISOString();
        await rpcUser(trx, "clear_thread_state", {
          user_id: userId,
          p_thread_id: threadId,
          p_read_at: readAt,
        } as any);

        const stored = await trx
          .selectFrom("thread_state")
          .select(["read_at"])
          .where("user_id", "=", userId)
          .where("thread_id", "=", threadId)
          .executeTakeFirst();

        // Guard correctly holds the thread unread: there is unseen content.
        expect(stored?.read_at).toBeNull();
      });
    });
  },
);
