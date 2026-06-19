import { describe, it, expect } from "vitest";

import { isLockTimeoutError, isStatementTimeoutError } from "./db";

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
    // 57014 is a distinct condition handled by isStatementTimeoutError: with a
    // short lock_timeout in place a 30s statement_timeout ran without
    // lock-waiting, which for the classify worker is transient DB saturation
    // (the scoring queries are all <120ms warm), not a row-lock wait.
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

describe("isStatementTimeoutError", () => {
  it("matches statement_timeout cancellation (57014)", () => {
    // The 30s statement_timeout fired. With lock_timeout=5s in place this is a
    // statement that genuinely ran 30s without lock-waiting — for the classify
    // worker that means transient DB saturation during a reclassification
    // burst, not a slow query (every scoring query is <120ms warm in prod). It
    // is self-healing: the consumer defers it to the hourly sweep, which
    // retries when contention has cleared.
    expect(
      isStatementTimeoutError(
        pgError("canceling statement due to statement timeout", "57014")
      )
    ).toBe(true);
  });

  it("matches by message when the SQLSTATE code is missing", () => {
    expect(
      isStatementTimeoutError(
        new Error("canceling statement due to statement timeout")
      )
    ).toBe(true);
  });

  it("does NOT match lock_timeout (55P03) — isLockTimeoutError owns those", () => {
    expect(
      isStatementTimeoutError(
        pgError("canceling statement due to lock timeout", "55P03")
      )
    ).toBe(false);
  });

  it("does NOT match deadlock (40P01) — retryOnTxnConflict owns those", () => {
    expect(
      isStatementTimeoutError(pgError("deadlock detected", "40P01"))
    ).toBe(false);
  });

  it("does NOT match unrelated errors", () => {
    expect(
      isStatementTimeoutError(pgError("duplicate key value", "23505"))
    ).toBe(false);
    expect(isStatementTimeoutError(new Error("connection terminated"))).toBe(
      false
    );
  });

  it("handles non-error inputs", () => {
    expect(isStatementTimeoutError(undefined)).toBe(false);
    expect(isStatementTimeoutError(null)).toBe(false);
    expect(isStatementTimeoutError({})).toBe(false);
  });
});
