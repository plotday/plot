/**
 * Tests for the legacy POST /sync/thread-unread backwards-compat shim.
 *
 * The shim exists because commit 3ff3bffa renamed thread_unread → thread_state
 * and deleted the old route, 404-ing every not-yet-upgraded client. These tests
 * pin the translation that keeps those clients working.
 *
 * Two groups:
 *   1. Pure-JS unit tests of legacyThreadUnreadToRpc — the exact mapping the
 *      handler runs (no DB, always run).
 *   2. DB integration (txn rollback) — feeds the translated RPC call through
 *      rpcUser against a real thread_state row and asserts the row contents.
 *      Skipped when DATABASE_URL is unset (e.g. CI without a DB).
 */

import { beforeAll, describe, expect, it } from "vitest";

import { legacyThreadUnreadToRpc } from "./thread-unread";

const USER = "00000000-0000-0000-0000-0000000000aa";
const THREAD = "00000000-0000-0000-0000-0000000000bb";

// ---------------------------------------------------------------------------
// Pure-JS unit tests: legacyThreadUnreadToRpc
// ---------------------------------------------------------------------------

describe("legacyThreadUnreadToRpc (unit)", () => {
  it("read_at present → clear_thread_state (mark read)", () => {
    const call = legacyThreadUnreadToRpc(USER, {
      thread_id: THREAD,
      read_at: "2026-05-24T00:00:00.000Z",
    });
    expect(call.fn).toBe("clear_thread_state");
    expect(call.args).toEqual({
      user_id: USER,
      p_thread_id: THREAD,
      p_read_at: "2026-05-24T00:00:00.000Z",
    });
  });

  it("read_at present carries bumped_at through", () => {
    const call = legacyThreadUnreadToRpc(USER, {
      thread_id: THREAD,
      read_at: "2026-05-24T00:00:00.000Z",
      bumped_at: "2026-05-24T01:00:00.000Z",
    });
    expect(call.fn).toBe("clear_thread_state");
    expect(call.args).toMatchObject({
      p_read_at: "2026-05-24T00:00:00.000Z",
      p_bumped_at: "2026-05-24T01:00:00.000Z",
    });
  });

  it("no read_at → upsert_thread_state marking unread (read_at NULL via default)", () => {
    const call = legacyThreadUnreadToRpc(USER, { thread_id: THREAD });
    expect(call.fn).toBe("upsert_thread_state");
    // p_set_read_at opts in to writing read_at; p_read_at is deliberately
    // absent so the RPC defaults it to NULL (= unread).
    expect(call.args).toEqual({
      user_id: USER,
      p_thread_id: THREAD,
      p_set_read_at: true,
      p_importance: 50,
      p_set_importance: false,
    });
    expect("p_read_at" in call.args).toBe(false);
  });

  it("no read_at + importance → carries importance and opts in", () => {
    const call = legacyThreadUnreadToRpc(USER, {
      thread_id: THREAD,
      importance: 30,
    });
    expect(call.fn).toBe("upsert_thread_state");
    expect(call.args).toMatchObject({
      p_importance: 30,
      p_set_importance: true,
      p_set_read_at: true,
    });
  });

  it("no read_at carries bumped_at through", () => {
    const call = legacyThreadUnreadToRpc(USER, {
      thread_id: THREAD,
      bumped_at: "2026-05-24T01:00:00.000Z",
    });
    expect(call.fn).toBe("upsert_thread_state");
    expect(call.args).toMatchObject({ p_bumped_at: "2026-05-24T01:00:00.000Z" });
  });

  it("urgency is ignored (dropped column, never translated)", () => {
    const call = legacyThreadUnreadToRpc(USER, {
      thread_id: THREAD,
      urgency: "interrupt",
    });
    // Still a valid mark-unread; urgency never leaks into the RPC args.
    expect(call.fn).toBe("upsert_thread_state");
    expect(JSON.stringify(call.args)).not.toContain("urgency");
    expect(JSON.stringify(call.args)).not.toContain("interrupt");
  });
});

// ---------------------------------------------------------------------------
// DB integration (txn rollback): translated RPC against a real thread_state row
// ---------------------------------------------------------------------------

const DATABASE_URL = process.env.DATABASE_URL;

describe.skipIf(!DATABASE_URL)(
  "DB integration: /sync/thread-unread shim → thread_state (txn rollback)",
  () => {
    let db: any;
    let userId = "";
    let threadId = "";

    beforeAll(async () => {
      const { createDb } = await import("../../db");
      db = createDb({ DATABASE_URL } as any);

      // Any user+thread with a settled, unrevoked filing so the RPCs take the
      // synchronous path (no defer / no "Thread not found").
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

    it("read_at record marks the thread read (read_at set)", async () => {
      const { rpcUser } = await import("../../rpc");
      const readAt = new Date().toISOString();
      const call = legacyThreadUnreadToRpc(userId, {
        thread_id: threadId,
        read_at: readAt,
      });
      expect(call.fn).toBe("clear_thread_state");

      await inRollback(async (trx) => {
        await rpcUser(trx, call.fn, call.args as any);
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

    it("record without read_at marks the thread unread (read_at NULL)", async () => {
      const { rpcUser } = await import("../../rpc");
      const call = legacyThreadUnreadToRpc(userId, { thread_id: threadId });
      expect(call.fn).toBe("upsert_thread_state");

      await inRollback(async (trx) => {
        // Seed a read marker first so we can prove the unread write clears it.
        await rpcUser(trx, "clear_thread_state", {
          user_id: userId,
          p_thread_id: threadId,
          p_read_at: new Date().toISOString(),
        } as any);

        await rpcUser(trx, call.fn, call.args as any);
        const stored = await trx
          .selectFrom("thread_state")
          .select(["read_at"])
          .where("user_id", "=", userId)
          .where("thread_id", "=", threadId)
          .executeTakeFirst();
        expect(stored?.read_at).toBeNull();
      });
    });

    it("importance is carried through to thread_state", async () => {
      const { rpcUser } = await import("../../rpc");
      const call = legacyThreadUnreadToRpc(userId, {
        thread_id: threadId,
        importance: 27,
      });

      await inRollback(async (trx) => {
        await rpcUser(trx, call.fn, call.args as any);
        const stored = await trx
          .selectFrom("thread_state")
          .select(["importance"])
          .where("user_id", "=", userId)
          .where("thread_id", "=", threadId)
          .executeTakeFirst();
        expect(stored?.importance).toBe(27);
      });
    });
  },
);
