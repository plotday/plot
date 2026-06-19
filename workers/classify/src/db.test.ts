import { describe, it, expect } from "vitest";

import { isLockTimeoutError } from "./db";

function pgError(message: string, code: string): Error & { code: string } {
  const e = new Error(message) as Error & { code: string };
  e.code = code;
  return e;
}

describe("isLockTimeoutError", () => {
  it("matches lock_timeout cancellation (55P03)", () => {
    // Raised when a statement set `lock_timeout` and gave up waiting for a row
    // lock. The classify settle/same UPDATE sets a short lock_timeout so it
    // bails fast when a concurrent per-user writer (reclassify / connector
    // sync / sibling settle) holds the thread_priority or user_sync row lock.
    expect(
      isLockTimeoutError(
        pgError("canceling statement due to lock timeout", "55P03")
      )
    ).toBe(true);
  });

  it("matches by message when the SQLSTATE code is missing", () => {
    expect(
      isLockTimeoutError(new Error("canceling statement due to lock timeout"))
    ).toBe(true);
  });

  it("does NOT match statement_timeout (57014)", () => {
    // With a short lock_timeout in place, a 30s statement_timeout means the
    // statement genuinely ran that long without lock-waiting — a real slow
    // query (e.g. classify SQL on a mega-user) worth capturing, not swallowing.
    expect(
      isLockTimeoutError(
        pgError("canceling statement due to statement timeout", "57014")
      )
    ).toBe(false);
  });

  it("does NOT match deadlock (40P01) — retryOnTxnConflict owns those", () => {
    expect(isLockTimeoutError(pgError("deadlock detected", "40P01"))).toBe(
      false
    );
  });

  it("does NOT match unrelated errors", () => {
    expect(isLockTimeoutError(pgError("duplicate key value", "23505"))).toBe(
      false
    );
    expect(isLockTimeoutError(new Error("connection terminated"))).toBe(false);
  });

  it("handles non-error inputs", () => {
    expect(isLockTimeoutError(undefined)).toBe(false);
    expect(isLockTimeoutError(null)).toBe(false);
    expect(isLockTimeoutError({})).toBe(false);
  });
});
