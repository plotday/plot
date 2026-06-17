import { describe, it, expect, vi } from "vitest";

import {
  withUserDb,
  isTransientDbError,
  isPoolExhaustedError,
  transientRetryDelayMs,
} from "./db";

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

describe("transientRetryDelayMs", () => {
  it("returns a positive jittered backoff for pool exhaustion", () => {
    // Pool exhaustion is a burst: wait briefly so peer connections drain before
    // re-requesting a slot. A tight (0ms) retry would just re-lose the race.
    const delay = transientRetryDelayMs(
      new Error("Timed out while waiting for an open slot in the pool.")
    );
    expect(delay).toBeGreaterThanOrEqual(100);
    expect(delay).toBeLessThanOrEqual(400);
  });

  it("returns 0 (immediate retry) for connection-recycling errors", () => {
    expect(
      transientRetryDelayMs(new Error("Connection terminated unexpectedly"))
    ).toBe(0);
    expect(
      transientRetryDelayMs(new Error("the database system is shutting down"))
    ).toBe(0);
  });

  it("returns 0 for non-transient errors", () => {
    expect(transientRetryDelayMs(new Error("duplicate key value"))).toBe(0);
  });
});
