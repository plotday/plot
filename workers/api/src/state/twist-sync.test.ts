import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type * as dbModule from "../db";
import { TRANSIENT_ALARM_RETRY_DELAYS_MS } from "./alarm-retry";
import { TwistSync } from "./twist-sync";

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

describe("TwistSync alarm failure handling", () => {
  const NOW = 1_750_000_000_000;
  const INSTANCE_ID = "019d91c2-4d0d-798e-b920-4340faf6b2ff";

  let storageMap: Map<string, unknown>;
  let setAlarm: ReturnType<typeof vi.fn>;
  let twistSync: TwistSync;

  beforeEach(() => {
    vi.spyOn(Date, "now").mockReturnValue(NOW);
    captureExceptionSpy.mockClear();
    captureSpy.mockClear();
    withDbMock.mockReset();

    storageMap = new Map<string, unknown>([["twistInstanceId", INSTANCE_ID]]);
    setAlarm = vi.fn();

    const ctx = {
      storage: {
        get: vi.fn(async (key: string) => storageMap.get(key)),
        put: vi.fn(async (key: string, value: unknown) => {
          storageMap.set(key, value);
        }),
        setAlarm,
      },
      waitUntil: vi.fn(),
    };
    const env = { POSTHOG_API_KEY: "key", POSTHOG_HOST: "host" };
    twistSync = new TwistSync(
      ctx as unknown as DurableObjectState,
      env as never
    );
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("reschedules without capturing on a transient failure", async () => {
    withDbMock.mockRejectedValue(
      new Error("Timed out while waiting for an open slot in the pool.")
    );

    await twistSync.alarm();

    expect(setAlarm).toHaveBeenCalledWith(
      NOW + TRANSIENT_ALARM_RETRY_DELAYS_MS[0]
    );
    expect(captureExceptionSpy).not.toHaveBeenCalled();
    expect(captureSpy).toHaveBeenCalledWith(
      expect.objectContaining({ event: "push.transient" })
    );
  });

  it("captures once the transient retry budget is exhausted", async () => {
    withDbMock.mockRejectedValue(new Error("Connection terminated unexpectedly"));

    for (let i = 0; i < TRANSIENT_ALARM_RETRY_DELAYS_MS.length; i++) {
      await twistSync.alarm();
    }
    expect(captureExceptionSpy).not.toHaveBeenCalled();

    await twistSync.alarm();

    expect(captureExceptionSpy).toHaveBeenCalledTimes(1);
    expect(setAlarm).toHaveBeenCalledTimes(TRANSIENT_ALARM_RETRY_DELAYS_MS.length);
  });

  it("captures immediately on an unexpected failure", async () => {
    withDbMock.mockRejectedValue(new Error("boom"));

    await twistSync.alarm();

    expect(captureExceptionSpy).toHaveBeenCalledTimes(1);
    expect(setAlarm).not.toHaveBeenCalled();
  });

  it("restores the retry budget on a fresh notify", async () => {
    withDbMock.mockRejectedValue(new Error("Connection terminated unexpectedly"));

    await twistSync.alarm();
    await twistSync.alarm();

    await twistSync.fetch(
      new Request("http://do/notify", {
        method: "POST",
        body: JSON.stringify({ id: INSTANCE_ID }),
      })
    );
    setAlarm.mockClear();

    await twistSync.alarm();

    // Back to the first rung of the ladder, not the third.
    expect(setAlarm).toHaveBeenCalledWith(
      NOW + TRANSIENT_ALARM_RETRY_DELAYS_MS[0]
    );
    expect(captureExceptionSpy).not.toHaveBeenCalled();
  });
});
