import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type * as dbModule from "../db";
import { TRANSIENT_ALARM_RETRY_DELAYS_MS } from "./alarm-retry";
import { ChannelRouter } from "./channel-router";

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

describe("ChannelRouter alarm failure handling", () => {
  const NOW = 1_750_000_000_000;
  const USER_ID = "019d91c2-4d0d-798e-b920-4340faf6b2ff";

  let storageMap: Map<string, unknown>;
  let setAlarm: ReturnType<typeof vi.fn>;
  let router: ChannelRouter;

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
    const env = { POSTHOG_API_KEY: "key", POSTHOG_HOST: "host" };
    router = new ChannelRouter(
      ctx as unknown as DurableObjectState,
      env as never
    );
    await ready;
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("reschedules without capturing on a transient failure", async () => {
    withDbMock.mockRejectedValue(
      new Error("Connection terminated unexpectedly")
    );

    await router.alarm();

    expect(setAlarm).toHaveBeenCalledWith(
      NOW + TRANSIENT_ALARM_RETRY_DELAYS_MS[0]
    );
    expect(captureExceptionSpy).not.toHaveBeenCalled();
  });

  it("captures once the transient retry budget is exhausted", async () => {
    withDbMock.mockRejectedValue(
      new Error("Timed out while waiting for an open slot in the pool.")
    );

    for (let i = 0; i < TRANSIENT_ALARM_RETRY_DELAYS_MS.length; i++) {
      await router.alarm();
    }
    expect(captureExceptionSpy).not.toHaveBeenCalled();

    await router.alarm();

    expect(captureExceptionSpy).toHaveBeenCalledTimes(1);
  });

  it("captures immediately on an unexpected failure without rescheduling", async () => {
    withDbMock.mockRejectedValue(new Error("boom"));

    await router.alarm();

    expect(captureExceptionSpy).toHaveBeenCalledTimes(1);
    expect(setAlarm).not.toHaveBeenCalled();
  });
});
