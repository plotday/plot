import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type * as dbModule from "../db";
import { TRANSIENT_ALARM_RETRY_DELAYS_MS } from "./alarm-retry";
import { UserSync } from "./user-sync";

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

describe("UserSync alarm failure handling", () => {
  const NOW = 1_750_000_000_000;
  const USER_ID = "019d91c2-4d0d-798e-b920-4340faf6b2ff";

  let storageMap: Map<string, unknown>;
  let setAlarm: ReturnType<typeof vi.fn>;
  let userSync: UserSync;

  beforeEach(async () => {
    vi.spyOn(Date, "now").mockReturnValue(NOW);
    captureExceptionSpy.mockClear();
    captureSpy.mockClear();
    withDbMock.mockReset();

    storageMap = new Map<string, unknown>([["userId", USER_ID]]);
    setAlarm = vi.fn();

    let ready: Promise<void> = Promise.resolve();
    const ctx = {
      storage: {
        get: vi.fn(async (key: string) => storageMap.get(key)),
        put: vi.fn(async (key: string, value: unknown) => {
          storageMap.set(key, value);
        }),
        setAlarm,
      },
      waitUntil: vi.fn(),
      blockConcurrencyWhile: vi.fn((fn: () => Promise<void>) => {
        ready = fn();
      }),
    };
    const env = {
      POSTHOG_API_KEY: "key",
      POSTHOG_HOST: "host",
      BROADCAST: {
        idFromName: vi.fn(() => "broadcast-id"),
        get: vi.fn(() => ({ send: vi.fn() })),
      },
      PUSH_NOTIFY: {
        idFromName: vi.fn(() => "push-id"),
        get: vi.fn(() => ({
          fetch: vi.fn(async () => new Response("OK")),
        })),
      },
    };
    userSync = new UserSync(
      ctx as unknown as DurableObjectState,
      env as never
    );
    await ready;
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("reschedules on a transient Hyperdrive/pg drop, like a DO reset", async () => {
    withDbMock.mockRejectedValue(
      new Error("Connection terminated unexpectedly")
    );

    await userSync.alarm();

    expect(setAlarm).toHaveBeenCalledWith(
      NOW + TRANSIENT_ALARM_RETRY_DELAYS_MS[0]
    );
    expect(captureExceptionSpy).not.toHaveBeenCalled();
    expect(captureSpy).toHaveBeenCalledWith(
      expect.objectContaining({ event: "push.transient" })
    );
  });

  it("reschedules on a transient DO reset (existing behavior)", async () => {
    withDbMock.mockRejectedValue(new Error("Network connection lost"));

    await userSync.alarm();

    expect(setAlarm).toHaveBeenCalledWith(
      NOW + TRANSIENT_ALARM_RETRY_DELAYS_MS[0]
    );
    expect(captureExceptionSpy).not.toHaveBeenCalled();
  });

  it("captures once the transient retry budget is exhausted", async () => {
    withDbMock.mockRejectedValue(new Error("Network connection lost"));

    for (let i = 0; i < TRANSIENT_ALARM_RETRY_DELAYS_MS.length; i++) {
      await userSync.alarm();
    }
    expect(captureExceptionSpy).not.toHaveBeenCalled();

    await userSync.alarm();

    expect(captureExceptionSpy).toHaveBeenCalledTimes(1);
  });

  it("captures immediately on an unexpected failure", async () => {
    withDbMock.mockRejectedValue(new Error("boom"));

    await userSync.alarm();

    expect(captureExceptionSpy).toHaveBeenCalledTimes(1);
    expect(setAlarm).not.toHaveBeenCalled();
  });
});
