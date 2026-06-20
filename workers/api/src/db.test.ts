import { describe, it, expect, vi } from "vitest";

import {
  withUserDb,
  isTransientDbError,
  isPoolExhaustedError,
  isLockContentionError,
  maxRetriesFor,
  transientRetryDelayMs,
  createDb,
  sql,
} from "./db";

const DATABASE_URL = process.env.DATABASE_URL;

/** Minimal stand-in for the Kysely handle: only `.transaction().execute(cb)` is used. */
function fakeDb(executeImpl: (cb: (trx: any) => Promise<any>) => Promise<any>) {
  return {
    transaction: () => ({ execute: executeImpl }),
  } as any;
}

function pgError(message: string, code: string): Error & { code: string } {
  const e = new Error(message) as Error & { code: string };
  e.code = code;
  return e;
}

describe("withUserDb deadlock retry", () => {
  it("retries the transaction on a deadlock (40P01) and eventually succeeds", async () => {
    let attempts = 0;
    const cb = vi.fn(async () => "ok");
    const db = fakeDb(async (inner) => {
      attempts++;
      if (attempts === 1) throw pgError("deadlock detected", "40P01");
      return inner({});
    });

    const result = await withUserDb(db, "user-1", cb);

    expect(result).toBe("ok");
    expect(attempts).toBe(2);
    // The callback only ran on the successful attempt — the rolled-back first
    // attempt threw before the transaction body executed.
    expect(cb).toHaveBeenCalledTimes(1);
  });

  it("retries on a serialization failure (40001)", async () => {
    let attempts = 0;
    const db = fakeDb(async (inner) => {
      attempts++;
      if (attempts === 1) throw pgError("could not serialize access", "40001");
      return inner({});
    });

    await expect(withUserDb(db, "u", async () => "x")).resolves.toBe("x");
    expect(attempts).toBe(2);
  });

  it("does not retry on a non-transient error (e.g. unique_violation)", async () => {
    let attempts = 0;
    const db = fakeDb(async () => {
      attempts++;
      throw pgError("duplicate key value", "23505");
    });

    await expect(withUserDb(db, "u", async () => "x")).rejects.toThrow(
      "duplicate key value"
    );
    expect(attempts).toBe(1);
  });

  it("propagates the deadlock after exhausting retries", async () => {
    let attempts = 0;
    const db = fakeDb(async () => {
      attempts++;
      throw pgError("deadlock detected", "40P01");
    });

    await expect(withUserDb(db, "u", async () => "x")).rejects.toThrow(
      "deadlock detected"
    );
    expect(attempts).toBe(3);
  });
});

describe("isTransientDbError", () => {
  it("matches pg's actual capitalized 'Connection terminated unexpectedly'", () => {
    // pg throws this exact string (capital C) from client.js when a pooled
    // Hyperdrive connection is recycled mid-query. The retry in withDb only
    // fires when this returns true.
    expect(isTransientDbError(new Error("Connection terminated unexpectedly"))).toBe(
      true
    );
  });

  it("matches a lowercase 'connection terminated'", () => {
    expect(isTransientDbError(new Error("connection terminated"))).toBe(true);
  });

  it("matches 'shutting down' regardless of case", () => {
    expect(
      isTransientDbError(new Error("the database system is shutting down"))
    ).toBe(true);
    expect(isTransientDbError(new Error("Server is Shutting Down"))).toBe(true);
  });

  it("matches Hyperdrive's pool-exhaustion 'open slot in the pool' error", () => {
    // Cloudflare Hyperdrive throws this exact string when all of its connection
    // slots are busy during a burst of concurrent DB use. Before this was
    // recognized, withDb's retry never fired and the burst surfaced as a flood
    // of captured exceptions (PostHog issue 019ed540).
    expect(
      isTransientDbError(
        new Error("Timed out while waiting for an open slot in the pool.")
      )
    ).toBe(true);
  });

  it("does not match an unrelated error", () => {
    expect(isTransientDbError(new Error("duplicate key value"))).toBe(false);
  });

  it("is safe for null/undefined/non-Error inputs", () => {
    expect(isTransientDbError(undefined)).toBe(false);
    expect(isTransientDbError(null)).toBe(false);
    expect(isTransientDbError({})).toBe(false);
  });
});

describe("isPoolExhaustedError", () => {
  it("matches Hyperdrive's connection-pool-exhaustion message", () => {
    expect(
      isPoolExhaustedError(
        new Error("Timed out while waiting for an open slot in the pool.")
      )
    ).toBe(true);
  });

  it("does not match connection-recycling errors", () => {
    // These are transient too, but they need a fresh connection — not a backoff.
    expect(
      isPoolExhaustedError(new Error("Connection terminated unexpectedly"))
    ).toBe(false);
    expect(
      isPoolExhaustedError(new Error("the database system is shutting down"))
    ).toBe(false);
  });

  it("is safe for null/undefined/non-Error inputs", () => {
    expect(isPoolExhaustedError(undefined)).toBe(false);
    expect(isPoolExhaustedError(null)).toBe(false);
    expect(isPoolExhaustedError({})).toBe(false);
  });
});

describe("isLockContentionError", () => {
  it("matches lock_timeout cancellation (55P03)", () => {
    // Raised when a statement gives up after `lock_timeout` waiting for a row
    // lock. The TwistSync cursor advance sets a short lock_timeout so it bails
    // fast instead of pinning a Hyperdrive slot for the full 30s.
    expect(
      isLockContentionError(
        pgError("canceling statement due to lock timeout", "55P03")
      )
    ).toBe(true);
  });

  it("matches statement_timeout cancellation (57014)", () => {
    // The historical surfacing of this contention (PostHog 019ed540): the tiny
    // twist_instance_sync UPSERT can only reach the 30s statement_timeout by
    // blocking on a row lock, so 57014 here means contention, not a slow query.
    expect(
      isLockContentionError(
        pgError("canceling statement due to statement timeout", "57014")
      )
    ).toBe(true);
  });

  it("matches by message when the pg code is absent", () => {
    expect(
      isLockContentionError(new Error("canceling statement due to lock timeout"))
    ).toBe(true);
    expect(
      isLockContentionError(
        new Error("canceling statement due to statement timeout")
      )
    ).toBe(true);
  });

  it("does not match a deadlock (40P01) — that is a real conflict, retried elsewhere", () => {
    expect(isLockContentionError(pgError("deadlock detected", "40P01"))).toBe(
      false
    );
  });

  it("does not match unrelated errors", () => {
    expect(isLockContentionError(pgError("duplicate key value", "23505"))).toBe(
      false
    );
    expect(isLockContentionError(new Error("connection terminated"))).toBe(false);
  });

  it("is safe for null/undefined/non-Error inputs", () => {
    expect(isLockContentionError(undefined)).toBe(false);
    expect(isLockContentionError(null)).toBe(false);
    expect(isLockContentionError({})).toBe(false);
  });
});

describe("maxRetriesFor", () => {
  it("gives pool exhaustion a multi-retry budget to ride out the burst", () => {
    // The fan-out that triggers pool exhaustion staggers TwistSync alarms across
    // a ~2s jitter window (MAX_JITTER_MS in twist-sync.ts). A single sub-second
    // retry can't outlast that, so the burst needs several backed-off retries.
    expect(
      maxRetriesFor(
        new Error("Timed out while waiting for an open slot in the pool.")
      )
    ).toBeGreaterThanOrEqual(3);
  });

  it("gives connection-termination errors a multi-retry budget too", () => {
    // "Connection terminated unexpectedly" (PostHog 019c4dff) fires from the same
    // saturation bursts as pool exhaustion, so a single immediate retry can't ride
    // it out either. It gets a multi-retry budget (first retry immediate for a
    // benign idle-recycle, then backoff — see transientRetryDelayMs).
    expect(
      maxRetriesFor(new Error("Connection terminated unexpectedly"))
    ).toBeGreaterThanOrEqual(2);
    expect(
      maxRetriesFor(new Error("the database system is shutting down"))
    ).toBeGreaterThanOrEqual(2);
  });

  it("does not retry non-transient errors", () => {
    expect(maxRetriesFor(new Error("duplicate key value"))).toBe(0);
  });

  it("is safe for null/undefined/non-Error inputs", () => {
    expect(maxRetriesFor(undefined)).toBe(0);
    expect(maxRetriesFor(null)).toBe(0);
    expect(maxRetriesFor({})).toBe(0);
  });
});

describe("transientRetryDelayMs", () => {
  const poolError = () =>
    new Error("Timed out while waiting for an open slot in the pool.");

  it("returns a positive jittered backoff for pool exhaustion", () => {
    // Pool exhaustion is a burst: wait so peer connections drain before
    // re-requesting a slot. A tight (0ms) retry would just re-lose the race.
    const delay = transientRetryDelayMs(poolError());
    expect(delay).toBeGreaterThan(0);
  });

  it("backs off exponentially across attempts, capped", () => {
    // Pin jitter to the midpoint so the growth is deterministic.
    const spy = vi.spyOn(Math, "random").mockReturnValue(0.5);
    try {
      const d1 = transientRetryDelayMs(poolError(), 1);
      const d2 = transientRetryDelayMs(poolError(), 2);
      const d3 = transientRetryDelayMs(poolError(), 3);
      expect(d2).toBeGreaterThan(d1);
      expect(d3).toBeGreaterThan(d2);
      // A very high attempt is capped, not unbounded.
      const dHigh = transientRetryDelayMs(poolError(), 20);
      expect(dHigh).toBeLessThanOrEqual(1000);
    } finally {
      spy.mockRestore();
    }
  });

  it("its cumulative budget across all pool retries spans the ~2s burst", () => {
    // Worst case (max jitter): the sum of the per-attempt ceilings the retry
    // loop can wait must cover MAX_JITTER_MS (2000ms), or it can't outlast the
    // burst. Pin jitter high so each delay is at its ceiling.
    const spy = vi.spyOn(Math, "random").mockReturnValue(0.999);
    try {
      const retries = maxRetriesFor(poolError());
      let total = 0;
      for (let attempt = 1; attempt <= retries; attempt++) {
        total += transientRetryDelayMs(poolError(), attempt);
      }
      expect(total).toBeGreaterThanOrEqual(2000);
    } finally {
      spy.mockRestore();
    }
  });

  it("connection-termination errors: first retry immediate, then backs off", () => {
    // A benign Hyperdrive idle-recycle just needs a fresh connection, so the
    // first retry is immediate (0ms). If it keeps failing it's saturation-driven
    // (same bursts as pool exhaustion), so later retries back off. Pin jitter to
    // the midpoint so the growth assertion is deterministic.
    const spy = vi.spyOn(Math, "random").mockReturnValue(0.5);
    try {
      for (const msg of [
        "Connection terminated unexpectedly",
        "the database system is shutting down",
      ]) {
        expect(transientRetryDelayMs(new Error(msg), 1)).toBe(0);
        expect(transientRetryDelayMs(new Error(msg), 2)).toBeGreaterThan(0);
        expect(transientRetryDelayMs(new Error(msg), 3)).toBeGreaterThan(
          transientRetryDelayMs(new Error(msg), 2)
        );
      }
    } finally {
      spy.mockRestore();
    }
  });

  it("returns 0 for non-transient errors at any attempt", () => {
    expect(transientRetryDelayMs(new Error("duplicate key value"))).toBe(0);
    expect(transientRetryDelayMs(new Error("duplicate key value"), 3)).toBe(0);
  });
});

describe.skipIf(!DATABASE_URL)("createDb connection GUCs", () => {
  // Every worker connection must carry bounded timeouts so a worker that stalls
  // mid-transaction (e.g. reloaded by `wrangler dev`, or awaiting a slow
  // external call) can't hold row locks indefinitely and wedge a thread's sync.
  // These are set via the libpq `-c` startup options in createDb so they
  // survive Hyperdrive connection pooling (a plain SET can be routed to a
  // different backend). See the 27-minute orphaned `idle in transaction`
  // backend that blocked every upsert_thread retry.
  it("sets idle_in_transaction_session_timeout and lock_timeout (not 0)", async () => {
    const db = createDb({ DATABASE_URL } as any);
    try {
      const idle = await sql<{ v: string }>`
        SELECT current_setting('idle_in_transaction_session_timeout') AS v
      `.execute(db);
      const lock = await sql<{ v: string }>`
        SELECT current_setting('lock_timeout') AS v
      `.execute(db);
      const stmt = await sql<{ v: string }>`
        SELECT current_setting('statement_timeout') AS v
      `.execute(db);
      // Disabled GUCs read as '0'; a bounded value is anything else.
      expect(idle.rows[0]?.v).not.toBe("0");
      expect(lock.rows[0]?.v).not.toBe("0");
      // Sanity-anchor on the pre-existing statement_timeout so a misconfigured
      // harness fails loudly rather than silently passing the two above.
      expect(stmt.rows[0]?.v).toBe("30s");
    } finally {
      await db.destroy();
    }
  });
});
