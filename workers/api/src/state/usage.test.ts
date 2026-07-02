import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type * as dbModule from "../db";
import { TRANSIENT_ALARM_RETRY_DELAYS_MS } from "./alarm-retry";
import { Usage } from "./usage";

const { captureExceptionSpy, captureSpy, withDbMock } = vi.hoisted(() => ({
  captureExceptionSpy: vi.fn(),
  captureSpy: vi.fn(),
  withDbMock: vi.fn(),
}));

vi.mock("posthog-node", () => ({
  PostHog: class {
    captureException = captureExceptionSpy;
    capture = captureSpy;
    async shutdown() {}
  },
}));

vi.mock("../db", async (importOriginal) => ({
  ...(await importOriginal<typeof dbModule>()),
  withDb: withDbMock,
}));

/**
 * Minimal in-memory stand-in for the DO SqlStorage surface Usage touches:
 * the `state` singleton row, the `usage` accumulator, and the burst counter
 * (which these tests ignore). Cursors support both `.next()` and iteration
 * (Array.from) like the real SqlStorage cursor.
 */
function makeFakeSql() {
  const tables = {
    stateRow: null as null | Record<string, unknown>,
    usageRows: [] as Array<{ cost_type: string; hour: number; amount: number }>,
  };

  function makeCursor(rows: unknown[]) {
    let i = 0;
    const iter = {
      next: () =>
        i < rows.length
          ? { done: false as const, value: rows[i++] }
          : { done: true as const, value: undefined },
      [Symbol.iterator]() {
        return iter;
      },
    };
    return iter;
  }

  const exec = (query: string, ...args: unknown[]) => {
    const q = query.trim();
    if (q.includes("SELECT * FROM state")) {
      return makeCursor(tables.stateRow ? [tables.stateRow] : []);
    }
    if (q.includes("SELECT cost_type, hour, amount FROM usage")) {
      return makeCursor([...tables.usageRows]);
    }
    if (q.startsWith("INSERT INTO state")) {
      tables.stateRow = {
        twistInstanceId: args[0],
        isDirty: args[1],
        nextFlushTime: args[2],
      };
      return makeCursor([]);
    }
    if (q.includes("INSERT INTO usage")) {
      tables.usageRows.push({
        cost_type: args[0] as string,
        hour: args[1] as number,
        amount: args[2] as number,
      });
      return makeCursor([]);
    }
    return makeCursor([]);
  };

  return { exec, tables };
}

describe("Usage alarm failure handling", () => {
  const NOW = 1_750_000_000_000;

  let fakeSql: ReturnType<typeof makeFakeSql>;
  let setAlarm: ReturnType<typeof vi.fn>;
  let usage: Usage;

  beforeEach(() => {
    vi.spyOn(Date, "now").mockReturnValue(NOW);
    captureExceptionSpy.mockClear();
    captureSpy.mockClear();
    withDbMock.mockReset();

    fakeSql = makeFakeSql();
    setAlarm = vi.fn();

    const ctx = {
      storage: { sql: fakeSql, setAlarm },
      waitUntil: vi.fn(),
    };
    const env = { POSTHOG_API_KEY: "key", POSTHOG_HOST: "host" };
    usage = new Usage(ctx as unknown as DurableObjectState, env as never);
    usage.init("twist-instance-1");
    // Buffer some unflushed spend, then drop the flush alarm it scheduled.
    usage.spend("worker:cpu_ms", 42);
    setAlarm.mockClear();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("re-arms the flush and keeps data dirty on a transient failure", async () => {
    withDbMock.mockRejectedValue(
      new Error("Connection terminated unexpectedly")
    );

    await usage.alarm();

    expect(setAlarm).toHaveBeenCalledWith(
      NOW + TRANSIENT_ALARM_RETRY_DELAYS_MS[0]
    );
    expect(captureExceptionSpy).not.toHaveBeenCalled();
    // The unflushed rows stay buffered and dirty for the retry.
    expect(fakeSql.tables.stateRow?.isDirty).toBe(1);
    expect(fakeSql.tables.usageRows.length).toBeGreaterThan(0);
  });

  it("captures once the transient retry budget is exhausted", async () => {
    withDbMock.mockRejectedValue(
      new Error("Timed out while waiting for an open slot in the pool.")
    );

    for (let i = 0; i < TRANSIENT_ALARM_RETRY_DELAYS_MS.length; i++) {
      await usage.alarm();
    }
    expect(captureExceptionSpy).not.toHaveBeenCalled();

    await usage.alarm();

    expect(captureExceptionSpy).toHaveBeenCalledTimes(1);
    // Data still buffered — the next spend() re-arms the flush.
    expect(fakeSql.tables.stateRow?.isDirty).toBe(1);
  });

  it("captures immediately on an unexpected failure without rescheduling", async () => {
    withDbMock.mockRejectedValue(new Error("boom"));

    await usage.alarm();

    expect(captureExceptionSpy).toHaveBeenCalledTimes(1);
    expect(setAlarm).not.toHaveBeenCalled();
    expect(fakeSql.tables.stateRow?.isDirty).toBe(1);
  });
});
