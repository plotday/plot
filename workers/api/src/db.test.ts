import { describe, it, expect, vi } from "vitest";

import { withUserDb } from "./db";

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
